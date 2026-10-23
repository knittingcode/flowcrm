<?php

declare(strict_types=1);

namespace App\Organizations\Application;

use App\Audit\Api\Actor;
use App\Audit\Api\AuditRecord;
use App\Audit\Api\AuditTrail;
use App\Identity\Api\UserDirectory;
use App\Organizations\Domain\LastAdminRule;
use App\Organizations\Domain\Membership;
use App\Organizations\Domain\MembershipRepository;
use App\Organizations\Domain\MembershipRole;
use App\Organizations\Domain\MembershipStatus;
use App\Organizations\Domain\Permission;
use App\Organizations\Domain\RolePolicy;
use App\Shared\Application\Transaction;
use Psr\Clock\ClockInterface;
use Symfony\Component\Uid\Uuid;

/**
 * Membership administration by an organization's ADMIN (FCRM-002 REQ-013 to
 * REQ-015, BR-02, BR-03; ADR-020). Every change runs in one transaction,
 * which:
 *
 * 1. locks the organization row, so changes of one organization run one
 *    after the other;
 * 2. reads the actor's own membership again under the lock: the
 *    authorization TenantGuard decided before the lock is not trusted for
 *    the write (none any more: ActorNotMember; the role no longer grants
 *    the permission: ActorNotPermitted);
 * 3. reads the target membership by organization and ID;
 * 4. counts the active ADMINs under the lock for the last-admin rule;
 * 5. writes the change and its audit event, which commit together.
 */
final readonly class ManageMemberships
{
    public function __construct(
        private OrganizationLock $lock,
        private MembershipRepository $memberships,
        private UserDirectory $users,
        private Transaction $transaction,
        private AuditTrail $audit,
        private ClockInterface $clock,
    ) {
    }

    /**
     * Adds an existing user with a role.
     *
     * @throws ActorNotMember
     * @throws ActorNotPermitted
     * @throws UnknownUser
     * @throws MembershipExists  also for a removed membership (there is no reactivation)
     */
    public function add(Uuid $organizationId, Uuid $actorUserId, string $email, MembershipRole $role, ?Uuid $requestId): MemberRow
    {
        return $this->asAdministrator($organizationId, $actorUserId, Permission::MembershipAdd, function (Actor $actor) use ($organizationId, $email, $role, $requestId): array {
            $userId = $this->users->idOfEmail($email) ?? throw new UnknownUser();
            if (null !== $this->memberships->ofOrganizationAndUser($organizationId, $userId)) {
                throw new MembershipExists();
            }
            $membership = new Membership(Uuid::v7(), $organizationId, $userId, $role, $this->clock->now());
            $this->memberships->add($membership);

            return [$membership, new AuditRecord('membership.added', 'membership', $membership->id(), $actor, $organizationId, ['role' => $role->value], $requestId)];
        });
    }

    /**
     * Changes the role of an active member. $newRole is asked for only once
     * the membership is known, so an unknown membership is a 404 before the
     * new role is validated. The same role again changes nothing and writes
     * no audit event.
     *
     * @param callable(): MembershipRole $newRole
     *
     * @throws ActorNotMember
     * @throws ActorNotPermitted
     * @throws MembershipNotFound
     * @throws LastAdmin
     */
    public function changeRole(Uuid $organizationId, Uuid $actorUserId, Uuid $membershipId, callable $newRole, ?Uuid $requestId): MemberRow
    {
        return $this->asAdministrator($organizationId, $actorUserId, Permission::MembershipChangeRole, function (Actor $actor) use ($organizationId, $membershipId, $newRole, $requestId): array {
            $target = $this->activeTarget($organizationId, $membershipId);
            $from = $target->role();
            $to = $newRole();
            if ($from === $to) {
                return [$target, null];
            }
            $this->keepAnAdmin($organizationId, $target, $to);
            $target->changeRole($to);

            return [$target, new AuditRecord('membership.role_changed', 'membership', $target->id(), $actor, $organizationId, ['roleFrom' => $from->value, 'roleTo' => $to->value], $requestId)];
        });
    }

    /**
     * Removes an active member (status REMOVED; the row stays, FCRM-003 C-11).
     *
     * @throws ActorNotMember
     * @throws ActorNotPermitted
     * @throws MembershipNotFound also for a membership that is already removed
     * @throws LastAdmin
     */
    public function remove(Uuid $organizationId, Uuid $actorUserId, Uuid $membershipId, ?Uuid $requestId): void
    {
        $this->asAdministrator($organizationId, $actorUserId, Permission::MembershipRemove, function (Actor $actor) use ($organizationId, $membershipId, $requestId): array {
            $target = $this->activeTarget($organizationId, $membershipId);
            $this->keepAnAdmin($organizationId, $target, null);
            $target->remove($this->clock->now());

            return [$target, new AuditRecord('membership.removed', 'membership', $target->id(), $actor, $organizationId, ['role' => $target->role()->value], $requestId)];
        });
    }

    /**
     * Runs $change in one transaction, under the organization lock, for an
     * actor whose active membership grants $permission under that lock, and
     * writes the audit event it returns (if any) in the same transaction.
     *
     * @param callable(Actor): array{Membership, ?AuditRecord} $change
     */
    private function asAdministrator(Uuid $organizationId, Uuid $actorUserId, Permission $permission, callable $change): MemberRow
    {
        $changed = $this->transaction->run(function () use ($organizationId, $actorUserId, $permission, $change): array {
            if (!$this->lock->lock($organizationId)) {
                throw new ActorNotMember();
            }
            $actor = $this->memberships->ofOrganizationAndUser($organizationId, $actorUserId);
            if (null === $actor || MembershipStatus::Active !== $actor->status()) {
                throw new ActorNotMember();
            }
            if (!RolePolicy::grants($actor->role(), $permission)) {
                throw new ActorNotPermitted($permission, $actor->role()->value);
            }

            $changed = $change(Actor::user($actorUserId, $actor->role()->value));
            if (null !== $changed[1]) {
                $this->audit->record($changed[1]);
            }

            return $changed;
        });
        $membership = $changed[0];

        return new MemberRow($membership->id(), $membership->userId(), $membership->role()->value);
    }

    private function activeTarget(Uuid $organizationId, Uuid $membershipId): Membership
    {
        $target = $this->memberships->ofOrganizationAndId($organizationId, $membershipId);
        if (null === $target || MembershipStatus::Active !== $target->status()) {
            throw new MembershipNotFound();
        }

        return $target;
    }

    /** @param MembershipRole|null $newRole null for a removal */
    private function keepAnAdmin(Uuid $organizationId, Membership $target, ?MembershipRole $newRole): void
    {
        if (LastAdminRule::violatedBy($target, $newRole, $this->memberships->activeAdminCount($organizationId))) {
            throw new LastAdmin();
        }
    }
}
