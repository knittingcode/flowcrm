<?php

declare(strict_types=1);

namespace App\Tests\Integration\Database;

use App\Tests\Support\TypedValues;
use Doctrine\DBAL\ArrayParameterType;
use Doctrine\DBAL\Connection;
use Doctrine\DBAL\DriverManager;
use Doctrine\Migrations\Configuration\Configuration;
use Doctrine\Migrations\Configuration\Connection\ExistingConnection;
use Doctrine\Migrations\Configuration\Migration\ExistingConfiguration;
use Doctrine\Migrations\DependencyFactory;
use Doctrine\Migrations\Metadata\Storage\TableMetadataStorageConfiguration;
use Doctrine\Migrations\MigratorConfiguration;
use Doctrine\Migrations\Version\Version;
use Symfony\Bundle\FrameworkBundle\Test\KernelTestCase;

/**
 * The FND-008 migration on a database that already holds core data, in a
 * throwaway database of the test server: up to the core schema, data in,
 * then the session and cache migration up and down again. Existing rows
 * survive both directions; only sessions and cache_items come and go.
 */
final class SessionCacheMigrationTest extends KernelTestCase
{
    use TypedValues;

    private const CORE = 'DoctrineMigrations\Version20261022000000';
    private const SESSIONS_AND_CACHE = 'DoctrineMigrations\Version20261022100000';

    private string $database;
    private Connection $scratch;

    protected function setUp(): void
    {
        $this->database = 'flowcrm_migration_'.bin2hex(random_bytes(4));
        $this->server()->executeStatement('CREATE DATABASE '.$this->database);
        $params = $this->server()->getParams();
        $this->scratch = DriverManager::getConnection([
            'driver' => 'pdo_pgsql',
            'host' => self::string($params['host'] ?? null),
            'port' => self::int($params['port'] ?? null),
            'user' => self::string($params['user'] ?? null),
            'password' => self::string($params['password'] ?? null),
            'dbname' => $this->database,
            'serverVersion' => '18',
        ]);
    }

    protected function tearDown(): void
    {
        $this->scratch->close();
        $this->server()->executeStatement('DROP DATABASE IF EXISTS '.$this->database.' WITH (FORCE)');
        parent::tearDown();
    }

    public function testExistingDataSurvivesTheMigrationUpAndDown(): void
    {
        $this->migrateTo(self::CORE);
        self::assertSame([], $this->tables(['sessions', 'cache_items']));
        $this->scratch->executeStatement("INSERT INTO users (id, email, password_hash, display_name, created_at) VALUES ('0192f0c4-7d1e-7b8a-9f3c-000000000001', 'anna@example.com', 'hash', 'Anna', now())");
        $this->scratch->executeStatement("INSERT INTO organizations (id, name, currency, timezone, created_at) VALUES ('0192f0c4-7d1e-7b8a-9f3c-000000000002', 'Acme', 'EUR', 'Europe/Warsaw', now())");
        $before = $this->coreRows();

        $this->migrateTo(self::SESSIONS_AND_CACHE);
        self::assertSame(['cache_items', 'sessions'], $this->tables(['sessions', 'cache_items']));
        self::assertSame($before, $this->coreRows());

        $this->migrateTo(self::CORE);
        self::assertSame([], $this->tables(['sessions', 'cache_items']));
        self::assertSame($before, $this->coreRows());

        $this->migrateTo(self::SESSIONS_AND_CACHE);
        self::assertSame($before, $this->coreRows());
    }

    private function migrateTo(string $version): void
    {
        $configuration = new Configuration();
        $configuration->addMigrationsDirectory('DoctrineMigrations', \dirname(__DIR__, 3).'/migrations');
        $configuration->setMetadataStorageConfiguration(new TableMetadataStorageConfiguration());
        $configuration->setTransactional(true);
        $factory = DependencyFactory::fromConnection(new ExistingConfiguration($configuration), new ExistingConnection($this->scratch));
        $factory->getMetadataStorage()->ensureInitialized();

        $plan = $factory->getMigrationPlanCalculator()->getPlanUntilVersion(new Version($version));
        $factory->getMigrator()->migrate($plan, new MigratorConfiguration());
    }

    /**
     * @param list<string> $names
     *
     * @return list<string>
     */
    private function tables(array $names): array
    {
        return array_map(self::string(...), $this->scratch->fetchFirstColumn(
            "SELECT tablename FROM pg_tables WHERE schemaname = 'public' AND tablename IN (?) ORDER BY tablename",
            [$names],
            [ArrayParameterType::STRING],
        ));
    }

    /** @return array<string, list<array<string, mixed>>> */
    private function coreRows(): array
    {
        return [
            'users' => $this->scratch->fetchAllAssociative('SELECT id, email, display_name, created_at FROM users ORDER BY id'),
            'organizations' => $this->scratch->fetchAllAssociative('SELECT id, name, currency, timezone, created_at FROM organizations ORDER BY id'),
            'schema_baseline' => $this->scratch->fetchAllAssociative('SELECT * FROM schema_baseline'),
        ];
    }

    private function server(): Connection
    {
        $db = self::getContainer()->get('doctrine.dbal.default_connection');
        self::assertInstanceOf(Connection::class, $db);

        return $db;
    }
}
