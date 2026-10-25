<?php

declare(strict_types=1);

namespace App\Tests\Integration\Database;

use App\Organizations\Application\ManageOrganizations;
use App\Organizations\Application\OrganizationLock;
use App\Organizations\Domain\MembershipRole;
use App\Tests\Support\Security\Fixtures;
use App\Tests\Support\Session\SeparateConnection;
use Doctrine\DBAL\Connection;
use Doctrine\DBAL\Exception\DriverException;
use Symfony\Bundle\FrameworkBundle\Test\KernelTestCase;
use Symfony\Component\Uid\Uuid;

/**
 * The organization lock of the membership changes (ADR-020) against the
 * real PostgreSQL: it excludes a second lock holder, but not the foreign
 * key checks of rows that reference the organization, and the operator's
 * console add takes it as well.
 */
final class OrganizationLockTest extends KernelTestCase
{
    private const LOCK_NOT_AVAILABLE = '55P03';

    private Fixtures $fixtures;
    private Connection $connection;
    private OrganizationLock $lock;
    private Uuid $organization;

    protected function setUp(): void
    {
        $container = self::getContainer();
        $this->fixtures = Fixtures::from($container);
        $this->connection = $this->fixtures->connection();
        $lock = $container->get(OrganizationLock::class);
        self::assertInstanceOf(OrganizationLock::class, $lock);
        $this->lock = $lock;
        $this->organization = $this->fixtures->organization('locked');
    }

    protected function tearDown(): void
    {
        while ($this->connection->isTransactionActive()) {
            $this->connection->rollBack();
        }
        parent::tearDown();
    }

    public function testTheLockExcludesASecondHolderButNotReferencingInserts(): void
    {
        $user = $this->fixtures->user('joining');
        $this->connection->beginTransaction();
        self::assertTrue($this->lock->lock($this->organization));

        $other = SeparateConnection::open();
        $other->exec("SET lock_timeout = '2s'");
        $start = microtime(true);
        $other->prepare("INSERT INTO memberships (id, organization_id, user_id, role, status, created_at) VALUES (?, ?, ?, 'REP', 'ACTIVE', now())")
            ->execute([Uuid::v7()->toRfc4122(), $this->organization->toRfc4122(), $user->id->toRfc4122()]);
        self::assertLessThan(1.0, microtime(true) - $start, 'the foreign key check does not wait for the lock');

        try {
            $other->prepare('SELECT id FROM organizations WHERE id = ? FOR NO KEY UPDATE NOWAIT')->execute([$this->organization->toRfc4122()]);
            self::fail('a second holder got the lock');
        } catch (\PDOException $e) {
            self::assertSame(self::LOCK_NOT_AVAILABLE, $e->getCode());
        }
    }

    public function testAnUnknownOrganizationIsNotLocked(): void
    {
        $this->connection->beginTransaction();

        self::assertFalse($this->lock->lock(Uuid::v7()));
    }

    public function testTheLockNeedsATransaction(): void
    {
        $this->expectException(\LogicException::class);

        $this->lock->lock($this->organization);
    }

    /** The operator's add waits for the lock, so it cannot race an ADMIN's add of the same user. */
    public function testTheOperatorAddTakesTheLock(): void
    {
        $user = $this->fixtures->user('operator-added');
        $holder = SeparateConnection::open();
        $holder->beginTransaction();
        $holder->prepare('SELECT id FROM organizations WHERE id = ? FOR NO KEY UPDATE')->execute([$this->organization->toRfc4122()]);
        $this->connection->executeStatement("SET lock_timeout = '500ms'");
        $organizations = self::getContainer()->get(ManageOrganizations::class);
        self::assertInstanceOf(ManageOrganizations::class, $organizations);
        $thrown = null;
        try {
            $organizations->addMember($this->organization, $user->email, MembershipRole::Rep);
        } catch (\Throwable $e) {
            $thrown = $e;
        } finally {
            $this->connection->executeStatement('RESET lock_timeout');
            $holder->rollBack();
        }
        self::assertInstanceOf(DriverException::class, $thrown, 'the add did not wait for the organization lock');
        self::assertSame(self::LOCK_NOT_AVAILABLE, $thrown->getSQLState());

        self::assertSame(0, $this->connection->fetchOne('SELECT count(*) FROM memberships WHERE organization_id = ?', [$this->organization->toRfc4122()]));

        // The failed transaction closed the entity manager: a new kernel, as
        // the next console run would have.
        self::ensureKernelShutdown();
        $organizations = self::getContainer()->get(ManageOrganizations::class);
        self::assertInstanceOf(ManageOrganizations::class, $organizations);
        $this->connection = Fixtures::from(self::getContainer())->connection();
        $organizations->addMember($this->organization, $user->email, MembershipRole::Rep);
        self::assertSame(1, $this->connection->fetchOne('SELECT count(*) FROM memberships WHERE organization_id = ?', [$this->organization->toRfc4122()]));
    }
}
