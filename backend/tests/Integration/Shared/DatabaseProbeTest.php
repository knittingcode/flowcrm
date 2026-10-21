<?php

declare(strict_types=1);

namespace App\Tests\Integration\Shared;

use App\Shared\Infrastructure\Database\DatabaseProbe;
use Doctrine\DBAL\Connection;
use Symfony\Bundle\FrameworkBundle\Test\KernelTestCase;

/**
 * Runs against the real, migrated PostgreSQL of the test project. Changes are
 * made inside a transaction that is always rolled back.
 */
final class DatabaseProbeTest extends KernelTestCase
{
    public function testMigratedDatabaseIsReady(): void
    {
        $result = $this->probe()->check();

        self::assertTrue($result->ready);
        self::assertNull($result->reason);
    }

    public function testAPendingMigrationMakesItNotReady(): void
    {
        $connection = $this->connection();
        $connection->beginTransaction();
        try {
            $deleted = $connection->executeStatement('DELETE FROM doctrine_migration_versions');
            self::assertGreaterThan(0, $deleted, 'the test database has applied migrations');

            $result = $this->probe()->check();

            self::assertFalse($result->ready);
            self::assertStringContainsString('pending', (string) $result->reason);
        } finally {
            $connection->rollBack();
        }

        self::assertTrue($this->probe()->check()->ready, 'restored after the rollback');
    }

    public function testTheBaselineRowExists(): void
    {
        self::assertSame('FCRM-FND-004', $this->connection()->fetchOne('SELECT baseline FROM schema_baseline WHERE id = 1'));
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
