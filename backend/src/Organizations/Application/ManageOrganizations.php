<?php

declare(strict_types=1);

namespace App\Organizations\Application;

use App\Audit\Api\Actor;
use App\Audit\Api\AuditRecord;
use App\Audit\Api\AuditTrail;
use App\Identity\Api\UserDirectory;
use App\Organizations\Domain\Currency;
use App\Organizations\Domain\Membership;
use App\Organizations\Domain\MembershipRepository;
use App\Organizations\Domain\MembershipRole;
use App\Organizations\Domain\Organization;
use App\Organizations\Domain\OrganizationRepository;
use App\Shared\Application\Transaction;
use Psr\Clock\ClockInterface;
use Symfony\Component\Uid\Uuid;

/**
 * The platform operator's provisioning (console only; FCRM-002: the
 * operator creates organizations with their first Admin). There is no HTTP
 * route for any of this. Every change is audited in the same transaction.
 */
final readonly class ManageOrganizations
{
    public function __construct(
        private OrganizationRepository $organizations,
        private MembershipRepository $memberships,
        private UserDirectory $users,
        private Transaction $transaction,
        private AuditTrail $audit,
        private ClockInterface $clock,
    ) {
    }

    /**
     * An organization with its first ADMIN, an existing user.
     *
     * @throws \InvalidArgumentException for an unknown user or invalid organization data
     */
    public function create(string $name, Currency $currency, string $timezone, string $adminEmail): Uuid
    {
        $adminId = $this->users->idOfEmail($adminEmail) ?? throw new \InvalidArgumentException('No user with this e-mail address exists.');
        $now = $this->clock->now();
        $organization = new Organization(Uuid::v7(), $name, $currency, $timezone, $now);
        $membership = new Membership(Uuid::v7(), $organization->id(), $adminId, MembershipRole::Admin, $now);

        $this->transaction->run(function () use ($organization, $membership): void {
            $this->organizations->add($organization);
            $this->memberships->add($membership);
            $this->audit->record(new AuditRecord('organization.created', 'organization', $organization->id(), Actor::operator(), $organization->id()));
            $this->audit->record(new AuditRecord('membership.added', 'membership', $membership->id(), Actor::operator(), $organization->id(), ['role' => $membership->role()->value]));
        });

        return $organization->id();
    }

    /**
     * Adds an existing user to an organization, for demonstration and test
     * setups. Changing or removing memberships is not part of FND-010B.
     *
     * @throws \InvalidArgumentException for an unknown organization or user, or an existing membership
     */
    public function addMember(Uuid $organizationId, string $email, MembershipRole $role): Uuid
    {
        if (null === $this->organizations->ofId($organizationId)) {
            throw new \InvalidArgumentException('No organization with this ID exists.');
        }
        $userId = $this->users->idOfEmail($email) ?? throw new \InvalidArgumentException('No user with this e-mail address exists.');
        if (null !== $this->memberships->ofOrganizationAndUser($organizationId, $userId)) {
            throw new \InvalidArgumentException('The user already has a membership in this organization (also a removed one).');
        }
        $membership = new Membership(Uuid::v7(), $organizationId, $userId, $role, $this->clock->now());

        $this->transaction->run(function () use ($membership, $organizationId): void {
            $this->memberships->add($membership);
            $this->audit->record(new AuditRecord('membership.added', 'membership', $membership->id(), Actor::operator(), $organizationId, ['role' => $membership->role()->value]));
        });

        return $membership->id();
    }
}
