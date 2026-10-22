<?php

declare(strict_types=1);

namespace App\Tests\Integration\Database;

use App\Shared\Infrastructure\Cache\RejectSchemaChanges;
use App\Tests\Support\TypedValues;
use Doctrine\DBAL\ArrayParameterType;
use Doctrine\DBAL\Configuration as DbalConfiguration;
use Doctrine\DBAL\Connection;
use Doctrine\DBAL\DriverManager;
use Doctrine\Migrations\Configuration\Configuration;
use Doctrine\Migrations\Configuration\Connection\ExistingConnection;
use Doctrine\Migrations\Configuration\Migration\ExistingConfiguration;
use Doctrine\Migrations\DependencyFactory;
use Doctrine\Migrations\Metadata\Storage\TableMetadataStorageConfiguration;
use Doctrine\Migrations\MigratorConfiguration;
use Doctrine\Migrations\Version\Version;
use PHPUnit\Framework\Attributes\DataProvider;
use Symfony\Bundle\FrameworkBundle\Test\KernelTestCase;
use Symfony\Component\Cache\Adapter\DoctrineDbalAdapter;

/**
 * The FND-008 migration in throwaway databases of the test server: existing
 * core data survives it up and down; it owns its tables (a cache write
 * before it creates none, a compatible existing table is adopted, an
 * incompatible one stops it without changes); and an interrupted run
 * leaves nothing behind and can be repeated.
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
        $this->scratch = $this->connect();
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
        $this->scratch->executeStatement("INSERT INTO audit_events (id, organization_id, occurred_at, actor_type, action, entity_type, changes) VALUES ('0192f0c4-7d1e-7b8a-9f3c-000000000003', '0192f0c4-7d1e-7b8a-9f3c-000000000002', now(), 'system', 'organization.created', 'organization', '{}')");
        $before = $this->coreRows();

        $this->migrateTo(self::SESSIONS_AND_CACHE);
        self::assertSame(['cache_items', 'sessions'], $this->tables(['sessions', 'cache_items']));
        self::assertSame($before, $this->coreRows());

        $this->migrateTo(self::CORE);
        self::assertSame([], $this->tables(['sessions', 'cache_items']));
        self::assertSame($before, $this->coreRows());

        $this->migrateTo(self::SESSIONS_AND_CACHE);
        self::assertSame($before, $this->coreRows());
        self::assertSame(0, $this->console('doctrine:schema:validate')[0], 'schema in sync');
    }

    /**
     * Before the migration, a cache write on a connection with the cache
     * connection's middleware creates no table (the adapter would create
     * one otherwise); the migration then runs normally.
     */
    public function testACacheWriteBeforeTheMigrationCreatesNoTable(): void
    {
        $this->migrateTo(self::CORE);
        $configuration = new DbalConfiguration();
        $configuration->setMiddlewares([new RejectSchemaChanges()]);
        $cache = $this->connect($configuration);
        $adapter = new DoctrineDbalAdapter($cache, 'early');

        self::assertSame('computed', $adapter->get('key', static fn (): string => 'computed'));
        self::assertSame([], $this->tables(['cache_items']), 'no unmanaged table');

        // Negative control: without the middleware the adapter creates it.
        $unguarded = new DoctrineDbalAdapter($this->connect(), 'early');
        $unguarded->get('key', static fn (): string => 'computed');
        self::assertSame(['cache_items'], $this->tables(['cache_items']));
        $this->scratch->executeStatement('DROP TABLE cache_items');

        $this->migrateTo(self::SESSIONS_AND_CACHE);
        self::assertSame(['cache_items', 'sessions'], $this->tables(['sessions', 'cache_items']));
        self::assertSame(0, $this->console('doctrine:schema:validate')[0]);
        $cache->close();
    }

    /**
     * A table that matches the migration's definition exactly (as an earlier
     * build let the cache adapter create it) is adopted with its rows; the
     * missing garbage-collection index is added.
     */
    public function testACompatibleExistingTableIsAdoptedWithItsRows(): void
    {
        $this->migrateTo(self::CORE);
        $this->scratch->executeStatement('CREATE TABLE cache_items (item_id VARCHAR(255) NOT NULL, item_data BYTEA NOT NULL, item_lifetime INT DEFAULT NULL, item_time INT NOT NULL, PRIMARY KEY (item_id))');
        $this->scratch->executeStatement("INSERT INTO cache_items VALUES ('ns:kept', 'v', NULL, 1)");
        $this->scratch->executeStatement('CREATE TABLE sessions (sess_id VARCHAR(128) NOT NULL, sess_data BYTEA NOT NULL, sess_lifetime INT NOT NULL, sess_time INT NOT NULL, PRIMARY KEY (sess_id))');

        [$exit, $output] = $this->console('doctrine:migrations:migrate', '--no-interaction', '--all-or-nothing');

        self::assertSame(0, $exit, $output);
        self::assertStringContainsString('Adopting the existing cache_items table', $output);
        self::assertStringContainsString('Adopting the existing sessions table', $output);
        self::assertSame(1, self::int($this->scratch->fetchOne("SELECT count(*) FROM cache_items WHERE item_id = 'ns:kept'")));
        self::assertSame(1, self::int($this->scratch->fetchOne("SELECT count(*) FROM pg_indexes WHERE indexname = 'sess_lifetime_idx'")));
        self::assertSame(0, $this->console('doctrine:schema:validate')[0]);
    }

    /**
     * @return iterable<string, array{string}>
     */
    public static function incompatibleTables(): iterable
    {
        yield 'cache key of another type' => ['CREATE TABLE cache_items (item_id TEXT NOT NULL, item_data BYTEA NOT NULL, item_lifetime INT DEFAULT NULL, item_time INT NOT NULL, PRIMARY KEY (item_id))'];
        yield 'cache table with an extra column' => ['CREATE TABLE cache_items (item_id VARCHAR(255) NOT NULL, item_data BYTEA NOT NULL, item_lifetime INT DEFAULT NULL, item_time INT NOT NULL, owner TEXT, PRIMARY KEY (item_id))'];
        yield 'cache time nullable' => ['CREATE TABLE cache_items (item_id VARCHAR(255) NOT NULL, item_data BYTEA NOT NULL, item_lifetime INT DEFAULT NULL, item_time INT, PRIMARY KEY (item_id))'];
        yield 'cache table without a primary key' => ['CREATE TABLE cache_items (item_id VARCHAR(255) NOT NULL, item_data BYTEA NOT NULL, item_lifetime INT DEFAULT NULL, item_time INT NOT NULL)'];
        yield 'session column with a default' => ['CREATE TABLE sessions (sess_id VARCHAR(128) NOT NULL, sess_data BYTEA NOT NULL, sess_lifetime INT NOT NULL DEFAULT 0, sess_time INT NOT NULL, PRIMARY KEY (sess_id))'];
        yield 'session index on the wrong column' => ['CREATE TABLE sessions (sess_id VARCHAR(128) NOT NULL, sess_data BYTEA NOT NULL, sess_lifetime INT NOT NULL, sess_time INT NOT NULL, PRIMARY KEY (sess_id)); CREATE INDEX sess_lifetime_idx ON sessions (sess_time)'];
    }

    #[DataProvider('incompatibleTables')]
    public function testAnIncompatibleExistingTableStopsTheMigrationWithoutChanges(string $ddl): void
    {
        $this->migrateTo(self::CORE);
        $this->scratch->executeStatement($ddl);
        $before = $this->definitions();

        [$exit, $output] = $this->console('doctrine:migrations:migrate', '--no-interaction', '--all-or-nothing');

        self::assertNotSame(0, $exit);
        self::assertMatchesRegularExpression('/already exists with a different definition|is not on \\(sess_lifetime\\)/', $output);
        self::assertSame($before, $this->definitions(), 'nothing was created, dropped or altered');
        self::assertSame(0, self::int($this->scratch->fetchOne('SELECT count(*) FROM doctrine_migration_versions WHERE version = ?', [self::SESSIONS_AND_CACHE])));
    }

    /**
     * The migration process dies while its CREATE TABLE waits for a lock
     * (another transaction creates a table of the same name): its
     * transaction is rolled back, nothing is left, and the next run works.
     */
    public function testAnInterruptedMigrationLeavesNothingAndCanBeRepeated(): void
    {
        $this->migrateTo(self::CORE);
        $blocker = $this->connect();
        $blocker->beginTransaction();
        $blocker->executeStatement('CREATE TABLE sessions (blocker INT)');

        $process = proc_open(
            ['php', 'bin/console', 'doctrine:migrations:migrate', '--no-interaction', '--all-or-nothing'],
            [0 => ['file', '/dev/null', 'r'], 1 => ['file', '/dev/null', 'w'], 2 => ['file', '/dev/null', 'w']],
            $pipes,
            \dirname(__DIR__, 3),
            $this->consoleEnv(),
        );
        self::assertIsResource($process);
        try {
            $waiting = 0;
            for ($i = 0; $i < 100 && 0 === $waiting; ++$i) {
                usleep(100_000);
                $waiting = self::int($this->server()->fetchOne("SELECT count(*) FROM pg_stat_activity WHERE datname = ? AND wait_event_type = 'Lock'", [$this->database]));
            }
            self::assertSame(1, $waiting, 'the migration waits inside its transaction');
        } finally {
            proc_terminate($process, 9);
            proc_close($process);
            $blocker->rollBack();
            $blocker->close();
        }
        for ($i = 0; $i < 50 && self::int($this->server()->fetchOne('SELECT count(*) FROM pg_stat_activity WHERE datname = ? AND pid <> pg_backend_pid()', [$this->database])) > 1; ++$i) {
            usleep(100_000);
        }

        self::assertSame([], $this->tables(['sessions', 'cache_items']), 'the interrupted run left nothing');
        self::assertSame(0, self::int($this->scratch->fetchOne('SELECT count(*) FROM doctrine_migration_versions WHERE version = ?', [self::SESSIONS_AND_CACHE])));

        [$exit, $output] = $this->console('doctrine:migrations:migrate', '--no-interaction', '--all-or-nothing');
        self::assertSame(0, $exit, $output);
        self::assertSame(['cache_items', 'sessions'], $this->tables(['sessions', 'cache_items']));
        self::assertSame(0, $this->console('doctrine:schema:validate')[0]);
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

    /** @return array<string, list<mixed>> */
    private function coreRows(): array
    {
        return [
            'users' => $this->scratch->fetchAllAssociative('SELECT id, email, display_name, created_at FROM users ORDER BY id'),
            'organizations' => $this->scratch->fetchAllAssociative('SELECT id, name, currency, timezone, created_at FROM organizations ORDER BY id'),
            'schema_baseline' => $this->scratch->fetchAllAssociative('SELECT * FROM schema_baseline'),
            'audit_events' => $this->scratch->fetchAllAssociative('SELECT id, action, changes FROM audit_events ORDER BY id'),
            'audit_triggers' => $this->scratch->fetchFirstColumn("SELECT tgname FROM pg_trigger WHERE tgrelid = 'audit_events'::regclass AND NOT tgisinternal ORDER BY tgname"),
        ];
    }

    /** @return list<array<string, mixed>> columns, keys and indexes of sessions and cache_items */
    private function definitions(): array
    {
        return $this->scratch->fetchAllAssociative(
            "SELECT 'column' AS kind, table_name::text AS t, column_name::text || ' ' || data_type || ' ' || is_nullable || ' ' || coalesce(column_default, '') AS d
               FROM information_schema.columns WHERE table_name IN ('sessions', 'cache_items')
             UNION ALL
             SELECT 'index', tablename::text, indexdef FROM pg_indexes WHERE tablename IN ('sessions', 'cache_items')
             ORDER BY 1, 2, 3",
        );
    }

    /**
     * Runs bin/console against the throwaway database.
     *
     * @return array{int, string} exit code and output
     */
    private function console(string ...$args): array
    {
        $process = proc_open(
            'php bin/console '.implode(' ', array_map(escapeshellarg(...), $args)).' 2>&1',
            [0 => ['file', '/dev/null', 'r'], 1 => ['pipe', 'w']],
            $pipes,
            \dirname(__DIR__, 3),
            $this->consoleEnv(),
        );
        self::assertIsResource($process);
        $output = (string) stream_get_contents($pipes[1]);
        fclose($pipes[1]);

        return [proc_close($process), $output];
    }

    /** @return array<string, string> */
    private function consoleEnv(): array
    {
        return [...getenv(), 'APP_ENV' => 'test', 'DATABASE_NAME' => $this->database];
    }

    private function connect(?DbalConfiguration $configuration = null): Connection
    {
        $params = $this->server()->getParams();

        return DriverManager::getConnection([
            'driver' => 'pdo_pgsql',
            'host' => self::string($params['host'] ?? null),
            'port' => self::int($params['port'] ?? null),
            'user' => self::string($params['user'] ?? null),
            'password' => self::string($params['password'] ?? null),
            'dbname' => $this->database,
            'serverVersion' => '18',
        ], $configuration);
    }

    private function server(): Connection
    {
        $db = self::getContainer()->get('doctrine.dbal.default_connection');
        self::assertInstanceOf(Connection::class, $db);

        return $db;
    }
}
