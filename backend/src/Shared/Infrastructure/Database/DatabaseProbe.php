<?php

declare(strict_types=1);

namespace App\Shared\Infrastructure\Database;

use Doctrine\DBAL\Connection;
use Doctrine\Migrations\DependencyFactory;

/**
 * Read-only checks of the PostgreSQL connection and the migration state.
 * Failures surface as exceptions; callers decide what to expose.
 */
final readonly class DatabaseProbe implements ReadinessCheck
{
    public function __construct(
        private Connection $connection,
        private DependencyFactory $migrations,
    ) {
    }

    public function databaseTime(): \DateTimeImmutable
    {
        $value = $this->connection->fetchOne("SELECT to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"')");
        if (!\is_string($value)) {
            throw new \UnexpectedValueException('The database returned no time.');
        }

        return new \DateTimeImmutable($value);
    }

    public function check(): ReadinessResult
    {
        $one = $this->connection->fetchOne('SELECT 1');
        if (1 !== $one && '1' !== $one) {
            return ReadinessResult::notReady('database query returned an unexpected result');
        }

        $calculator = $this->migrations->getMigrationStatusCalculator();
        $pending = \count($calculator->getNewMigrations());
        $unknown = \count($calculator->getExecutedUnavailableMigrations());
        if (0 !== $pending || 0 !== $unknown) {
            return ReadinessResult::notReady(\sprintf('migrations not current (%d pending, %d unknown)', $pending, $unknown));
        }

        return ReadinessResult::ready();
    }
}
