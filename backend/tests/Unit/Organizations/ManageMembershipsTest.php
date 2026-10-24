<?php

declare(strict_types=1);

namespace App\Tests\Unit\Organizations;

use App\Audit\Api\AuditRecord;
use App\Audit\Api\AuditTrail;
use App\Identity\Api\UserDirectory;
use App\Organizations\Application\ActorNotMember;
use App\Organizations\Application\ActorNotPermitted;
use App\Organizations\Application\LastAdmin;
use App\Organizations\Application\ManageMemberships;
use App\Organizations\Application\MembershipExists;
use App\Organizations\Application\MembershipNotFound;
use App\Organizations\Application\OrganizationLock;
use App\Organizations\Application\UnknownUser;
use App\Organizations\Domain\Membership;
use App\Organizations\Domain\MembershipRepository;
use App\Organizations\Domain\MembershipRole;
use App\Organizations\Domain\MembershipStatus;
use App\Shared\Application\Transaction;
use PHPUnit\Framework\TestCase;
use Symfony\Component\Clock\MockClock;
use Symfony\Component\Uid\Uuid;

/**
 * The order and the checks of the membership use cases, with in-memory
 * collaborators that record what happens inside the transaction. The
 * database behaviour (row lock, rollback) is covered by
 * MembershipAdministrationTest.
 */
final class ManageMembershipsTest extends TestCase
{
    /** @var list<string> */
    private array $journal = [];
    private bool $inTransaction = false;
    /** @var list<AuditRecord> */
    private array $events = [];
    /** @var array<string, Membership> */
    private array $memberships = [];
    /** @var array<string, Uuid> */
    private array $users = [];
    private Uuid $organization;
    private Uuid $admin;

    protected function setUp(): void
    {
        $this->organization = Uuid::v7();
        $this->admin = $this->user('admin@example.test');
        $this->membership($this->organization, $this->admin, MembershipRole::Admin);
    }

    public function testAnAdminAddsAnExistingUserUnderTheLock(): void
    {
        $user = $this->user('new@example.test');

        $row = $this->useCase()->add($this->organization, $this->admin, 'new@example.test', MembershipRole::Manager, $request = Uuid::v7());

        self::assertSame('MANAGER', $row->role);
        self::assertTrue($row->userId->equals($user));
        self::assertSame(['begin', 'lock', 'actor', 'actor', 'add', 'audit', 'commit'], $this->journal, 'the actor, then the duplicate check');
        self::assertCount(1, $this->events);
        $event = $this->events[0];
        self::assertSame('membership.added', $event->action);
        self::assertSame('membership', $event->entityType);
        self::assertTrue($row->membershipId->equals($event->entityId));
        self::assertSame(['role' => 'MANAGER'], $event->changes);
        self::assertSame('user', $event->actor->type);
        self::assertSame('ADMIN', $event->actor->role);
        self::assertTrue($this->admin->equals($event->actor->userId));
        self::assertTrue($this->organization->equals($event->organizationId));
        self::assertSame($request, $event->requestId);
    }

    public function testUnknownUsersAndExistingMembershipsAreRefused(): void
    {
        $this->assertRefused(UnknownUser::class, fn () => $this->useCase()->add($this->organization, $this->admin, 'nobody@example.test', MembershipRole::Rep, null));

        $removed = $this->user('removed@example.test');
        $this->membership($this->organization, $removed, MembershipRole::Rep)->remove(new \DateTimeImmutable());
        $this->assertRefused(MembershipExists::class, fn () => $this->useCase()->add($this->organization, $this->admin, 'removed@example.test', MembershipRole::Rep, null));
        $this->assertRefused(MembershipExists::class, fn () => $this->useCase()->add($this->organization, $this->admin, 'admin@example.test', MembershipRole::Rep, null));
    }

    public function testTheActorIsCheckedAgainUnderTheLock(): void
    {
        $manager = $this->user('manager@example.test');
        $this->membership($this->organization, $manager, MembershipRole::Manager);
        $target = $this->membership($this->organization, $this->user('rep@example.test'), MembershipRole::Rep);
        $useCase = $this->useCase();

        $this->assertRefused(ActorNotPermitted::class, fn () => $useCase->changeRole($this->organization, $manager, $target->id(), static fn (): MembershipRole => MembershipRole::Admin, null));
        $this->assertRefused(ActorNotPermitted::class, fn () => $useCase->remove($this->organization, $manager, $target->id(), null));
        $this->assertRefused(ActorNotPermitted::class, fn () => $useCase->add($this->organization, $manager, 'admin@example.test', MembershipRole::Rep, null));
        $this->assertRefused(ActorNotMember::class, fn () => $useCase->remove($this->organization, $this->user('outsider@example.test'), $target->id(), null));
        $this->assertRefused(ActorNotMember::class, fn () => $useCase->remove(Uuid::v7(), $this->admin, $target->id(), null));

        $this->memberships[$this->admin->toRfc4122()]->remove(new \DateTimeImmutable());
        $this->assertRefused(ActorNotMember::class, fn () => $useCase->remove($this->organization, $this->admin, $target->id(), null));
        self::assertSame(MembershipStatus::Active, $target->status());
    }

    public function testTheTargetIsLookedUpInTheOrganizationOnly(): void
    {
        $other = Uuid::v7();
        $foreign = $this->membership($other, $this->user('foreign@example.test'), MembershipRole::Rep);
        $removed = $this->membership($this->organization, $this->user('gone@example.test'), MembershipRole::Rep);
        $removed->remove(new \DateTimeImmutable());
        $useCase = $this->useCase();

        foreach ([$foreign->id(), $removed->id(), Uuid::v7()] as $id) {
            $this->assertRefused(MembershipNotFound::class, fn () => $useCase->remove($this->organization, $this->admin, $id, null));
            $this->assertRefused(MembershipNotFound::class, fn () => $useCase->changeRole($this->organization, $this->admin, $id, static fn (): MembershipRole => MembershipRole::Admin, null));
        }
        self::assertSame(MembershipRole::Rep, $foreign->role());
        self::assertSame(MembershipStatus::Active, $foreign->status());
    }

    public function testTheNewRoleIsAskedForOnlyOnceTheTargetIsKnown(): void
    {
        $this->assertRefused(MembershipNotFound::class, fn () => $this->useCase()->changeRole($this->organization, $this->admin, Uuid::v7(), function (): MembershipRole {
            $this->journal[] = 'role asked';

            return MembershipRole::Rep;
        }, null));

        self::assertNotContains('role asked', $this->journal());
    }

    public function testARoleChangeIsAuditedWithBothRoles(): void
    {
        $target = $this->membership($this->organization, $this->user('rep@example.test'), MembershipRole::Rep);

        $row = $this->useCase()->changeRole($this->organization, $this->admin, $target->id(), static fn (): MembershipRole => MembershipRole::Manager, null);

        self::assertSame('MANAGER', $row->role);
        self::assertSame(MembershipRole::Manager, $target->role());
        self::assertSame(['begin', 'lock', 'actor', 'target', 'count', 'audit', 'commit'], $this->journal);
        self::assertSame('membership.role_changed', $this->events[0]->action);
        self::assertSame(['roleFrom' => 'REP', 'roleTo' => 'MANAGER'], $this->events[0]->changes);
    }

    public function testTheSameRoleChangesNothingAndIsNotAudited(): void
    {
        $target = $this->membership($this->organization, $this->user('rep@example.test'), MembershipRole::Rep);

        $row = $this->useCase()->changeRole($this->organization, $this->admin, $target->id(), static fn (): MembershipRole => MembershipRole::Rep, null);

        self::assertSame('REP', $row->role);
        self::assertSame([], $this->events);
    }

    public function testTheLastAdminCannotBeDemotedOrRemoved(): void
    {
        $self = $this->memberships[$this->admin->toRfc4122()];
        $useCase = $this->useCase();

        $this->assertRefused(LastAdmin::class, fn () => $useCase->changeRole($this->organization, $this->admin, $self->id(), static fn (): MembershipRole => MembershipRole::Manager, null));
        $this->assertRefused(LastAdmin::class, fn () => $useCase->remove($this->organization, $this->admin, $self->id(), null));
        self::assertSame(MembershipRole::Admin, $self->role());
        self::assertSame(MembershipStatus::Active, $self->status());
        self::assertSame([], $this->events);

        $second = $this->user('second@example.test');
        $this->membership($this->organization, $second, MembershipRole::Admin);
        $useCase->changeRole($this->organization, $this->admin, $self->id(), static fn (): MembershipRole => MembershipRole::Rep, null);
        self::assertSame(MembershipRole::Rep, $self->role(), 'with a second ADMIN the first may demote itself');
        $this->assertRefused(ActorNotPermitted::class, fn () => $useCase->remove($this->organization, $this->admin, $self->id(), null));
    }

    public function testARemovalIsSoftAndAudited(): void
    {
        $target = $this->membership($this->organization, $this->user('rep@example.test'), MembershipRole::Rep);

        $this->useCase()->remove($this->organization, $this->admin, $target->id(), null);

        self::assertSame(MembershipStatus::Removed, $target->status());
        self::assertNotNull($target->removedAt());
        self::assertSame('membership.removed', $this->events[0]->action);
        self::assertSame(['role' => 'REP'], $this->events[0]->changes);
        $this->assertRefused(MembershipNotFound::class, fn () => $this->useCase()->remove($this->organization, $this->admin, $target->id(), null));
    }

    /** @param class-string<\Throwable> $expected */
    private function assertRefused(string $expected, \Closure $call): void
    {
        $this->journal = [];
        $events = \count($this->events);
        try {
            $call();
            self::fail('not refused: '.$expected);
        } catch (\DomainException $e) {
            self::assertInstanceOf($expected, $e);
        }
        $journal = $this->journal();
        self::assertSame('lock', $journal[1] ?? null, 'the lock comes first');
        self::assertSame('rollback', end($journal));
        self::assertCount($events, $this->events, 'no audit event');
    }

    /** @return list<string> */
    private function journal(): array
    {
        return $this->journal;
    }

    private function useCase(): ManageMemberships
    {
        $this->journal = [];

        return new ManageMemberships($this->lock(), $this->repository(), $this->directory(), $this->transaction(), $this->audit(), new MockClock('@1761210000'));
    }

    private function user(string $email): Uuid
    {
        return $this->users[$email] = Uuid::v7();
    }

    private function membership(Uuid $organization, Uuid $user, MembershipRole $role): Membership
    {
        return $this->memberships[$user->toRfc4122().($organization->equals($this->organization) ? '' : '@'.$organization->toRfc4122())] = new Membership(Uuid::v7(), $organization, $user, $role, new \DateTimeImmutable());
    }

    private function inside(string $step): void
    {
        self::assertTrue($this->inTransaction, $step.' outside the transaction');
        $this->journal[] = $step;
    }

    private function transaction(): Transaction
    {
        return new class($this) implements Transaction {
            public function __construct(private readonly ManageMembershipsTest $test)
            {
            }

            public function run(callable $work): mixed
            {
                return $this->test->runTransaction($work);
            }
        };
    }

    /**
     * @template T
     *
     * @param callable(): T $work
     *
     * @return T
     *
     * @internal for the Transaction fake
     */
    public function runTransaction(callable $work): mixed
    {
        self::assertFalse($this->inTransaction, 'no nested transaction');
        $this->inTransaction = true;
        $this->journal[] = 'begin';
        try {
            $result = $work();
            $this->journal[] = 'commit';

            return $result;
        } catch (\Throwable $e) {
            $this->journal[] = 'rollback';

            throw $e;
        } finally {
            $this->inTransaction = false;
        }
    }

    /** @internal for the fakes */
    public function step(string $step): void
    {
        $this->inside($step);
    }

    /** @internal for the fakes */
    public function record(AuditRecord $record): void
    {
        $this->inside('audit');
        $this->events[] = $record;
    }

    /**
     * @internal for the fakes
     *
     * @return array<string, Membership>
     */
    public function all(): array
    {
        return $this->memberships;
    }

    /** @internal for the fakes */
    public function put(Membership $membership): void
    {
        $this->inside('add');
        $this->memberships[$membership->userId()->toRfc4122().'+'.$membership->id()->toRfc4122()] = $membership;
    }

    /**
     * @internal for the fakes
     *
     * @return array<string, Uuid>
     */
    public function knownUsers(): array
    {
        return $this->users;
    }

    public function organization(): Uuid
    {
        return $this->organization;
    }

    private function lock(): OrganizationLock
    {
        return new class($this) implements OrganizationLock {
            public function __construct(private readonly ManageMembershipsTest $test)
            {
            }

            public function lock(Uuid $organizationId): bool
            {
                $this->test->step('lock');

                return $organizationId->equals($this->test->organization());
            }
        };
    }

    private function audit(): AuditTrail
    {
        return new class($this) implements AuditTrail {
            public function __construct(private readonly ManageMembershipsTest $test)
            {
            }

            public function record(AuditRecord $record): void
            {
                $this->test->record($record);
            }
        };
    }

    private function directory(): UserDirectory
    {
        return new class($this) implements UserDirectory {
            public function __construct(private readonly ManageMembershipsTest $test)
            {
            }

            public function profiles(array $ids): array
            {
                return [];
            }

            public function idOfEmail(string $email): ?Uuid
            {
                return $this->test->knownUsers()[strtolower($email)] ?? null;
            }
        };
    }

    private function repository(): MembershipRepository
    {
        return new class($this) implements MembershipRepository {
            public function __construct(private readonly ManageMembershipsTest $test)
            {
            }

            public function add(Membership $membership): void
            {
                $this->test->put($membership);
            }

            public function ofOrganizationAndUser(Uuid $organizationId, Uuid $userId): ?Membership
            {
                // The actor's lookup and the duplicate check of add() both use it.
                $this->test->step('actor');
                foreach ($this->test->all() as $membership) {
                    if ($membership->organizationId()->equals($organizationId) && $membership->userId()->equals($userId)) {
                        return $membership;
                    }
                }

                return null;
            }

            public function ofOrganizationAndId(Uuid $organizationId, Uuid $membershipId): ?Membership
            {
                $this->test->step('target');
                foreach ($this->test->all() as $membership) {
                    if ($membership->organizationId()->equals($organizationId) && $membership->id()->equals($membershipId)) {
                        return $membership;
                    }
                }

                return null;
            }

            public function activeAdminCount(Uuid $organizationId): int
            {
                $this->test->step('count');

                return \count(array_filter($this->test->all(), static fn (Membership $m): bool => $m->organizationId()->equals($organizationId) && MembershipRole::Admin === $m->role() && MembershipStatus::Active === $m->status()));
            }
        };
    }
}
