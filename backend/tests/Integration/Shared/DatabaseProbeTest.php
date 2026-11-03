<?php

declare(strict_types=1);

namespace App\Tests\Integration\Shared;

use App\Shared\Application\Health\ReadinessCheck;
use App\Shared\Application\SystemStatus\DatabaseTime;
use App\Shared\Infrastructure\Database\DatabaseProbe;
use App\Tests\Support\Database\TestDatabase;
use Doctrine\DBAL\Connection;
use Doctrine\Migrations\Configuration\Configuration;
use Doctrine\Migrations\Configuration\Connection\ExistingConnection;
use Doctrine\Migrations\Configuration\Migration\ExistingConfiguration;
use Doctrine\Migrations\DependencyFactory;
use Doctrine\Migrations\Metadata\Storage\TableMetadataStorageConfiguration;
use Symfony\Bundle\FrameworkBundle\Test\KernelTestCase;

/**
 * Runs against the real, migrated PostgreSQL of the test project, as the
 * runtime role like the API. Changes are made by the owner inside a
 * transaction that is always rolled back.
 */
final class DatabaseProbeTest extends KernelTestCase
{
    public function testMigratedDatabaseIsReady(): void
    {
        $result = $this->probe()->check();

        self::assertTrue($result->ready);
        self::assertNull($result->reason);
    }

    /**
     * Only the owner may change the migration history, so the pending state
     * is made in an owner transaction and checked by a probe on that same
     * connection (it sees the uncommitted change); the runtime probe is
     * checked again afterwards.
     */
    public function testAPendingMigrationMakesItNotReady(): void
    {
        $owner = TestDatabase::owner();
        $owner->beginTransaction();
        try {
            $deleted = $owner->executeStatement('DELETE FROM doctrine_migration_versions');
            self::assertGreaterThan(0, $deleted, 'the test database has applied migrations');

            $result = new DatabaseProbe($owner, $this->migrationsOn($owner))->check();

            self::assertFalse($result->ready);
            self::assertStringContainsString('pending', (string) $result->reason);
        } finally {
            $owner->rollBack();
            $owner->close();
        }

        self::assertTrue($this->probe()->check()->ready, 'the runtime probe is ready');
    }

    public function testTheRuntimeRoleCannotChangeTheMigrationHistory(): void
    {
        $this->expectExceptionMessage('permission denied for table doctrine_migration_versions');
        $this->connection()->executeStatement('DELETE FROM doctrine_migration_versions');
    }

    public function testTheApplicationContractsAreServedByTheProbe(): void
    {
        foreach ([ReadinessCheck::class, DatabaseTime::class] as $contract) {
            self::assertInstanceOf(DatabaseProbe::class, self::getContainer()->get($contract), $contract);
        }
    }

    /** Read as the owner: the runtime role has no access to schema_baseline (manifest). */
    public function testTheBaselineRowExists(): void
    {
        self::assertSame('FCRM-FND-004', TestDatabase::owner()->fetchOne('SELECT baseline FROM schema_baseline WHERE id = 1'));
    }

    private function migrationsOn(Connection $connection): DependencyFactory
    {
        $configuration = new Configuration();
        $configuration->addMigrationsDirectory('DoctrineMigrations', \dirname(__DIR__, 3).'/migrations');
        $configuration->setMetadataStorageConfiguration(new TableMetadataStorageConfiguration());

        return DependencyFactory::fromConnection(new ExistingConfiguration($configuration), new ExistingConnection($connection));
    }

    private function probe(): DatabaseProbe
    {
        $probe = self::getContainer()->get(DatabaseProbe::class);
        self::assertInstanceOf(DatabaseProbe::class, $probe);

        return $probe;
    }

    private function connection(): Connection
    {
        $connection = self::getContainer()->get(Connection::class);
        self::assertInstanceOf(Connection::class, $connection);

        return $connection;
    }
}
