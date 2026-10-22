<?php

declare(strict_types=1);

namespace App\Tests\Integration\Database;

use App\Shared\Infrastructure\Cache\RejectSchemaChanges;
use App\Tests\Support\Database\TestDatabase;
use App\Tests\Support\TypedValues;
use Doctrine\DBAL\ArrayParameterType;
use Doctrine\DBAL\Configuration as DbalConfiguration;
use Doctrine\DBAL\Connection;
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
 * core data survives it up and down; it only creates its tables (a cache
 * write before it creates none, and any existing relation of the same name
 * stops it without changes, even one identical to its own definition); the
 * documented rename recovery works; and an interrupted run leaves nothing
 * behind and can be repeated.
 */
final class SessionCacheMigrationTest extends KernelTestCase
{
    use TypedValues;

    private const CORE = 'DoctrineMigrations\Version20261022000000';
    private const SESSIONS_AND_CACHE = 'DoctrineMigrations\Version20261022100000';
    // Exactly the migration's own definitions.
    private const CACHE_ITEMS = 'CREATE TABLE cache_items (item_id VARCHAR(255) NOT NULL, item_data BYTEA NOT NULL, item_lifetime INT DEFAULT NULL, item_time INT NOT NULL, PRIMARY KEY (item_id))';
    private const SESSIONS = 'CREATE TABLE sessions (sess_id VARCHAR(128) NOT NULL, sess_data BYTEA NOT NULL, sess_lifetime INT NOT NULL, sess_time INT NOT NULL, PRIMARY KEY (sess_id))';

    private string $database;
    private Connection $scratch;
    private ?Connection $admin = null;
    private ?Connection $adminScratch = null;

    protected function setUp(): void
    {
        $this->database = 'flowcrm_migration_'.bin2hex(random_bytes(4));
        // Owned by flowcrm_owner, like schema public of the real database.
        $this->server()->executeStatement('CREATE DATABASE '.$this->database.' OWNER '.TestDatabase::OWNER);
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

    public function testRunningTheMigrationAgainChangesNothing(): void
    {
        [$exit, $output] = $this->console('doctrine:migrations:migrate', '--no-interaction', '--all-or-nothing');
        self::assertSame(0, $exit, $output);
        $before = $this->catalog();

        [$exit, $output] = $this->console('doctrine:migrations:migrate', '--no-interaction', '--all-or-nothing', '--allow-no-migration');

        self::assertSame(0, $exit, $output);
        self::assertStringContainsString('Already at the latest version', $output);
        self::assertSame($before, $this->catalog());
    }

    /**
     * Every relation that takes one of the migration's names, including one
     * that looks exactly like the expected table (as the cache adapter could
     * create it), and the variants an adoption check could miss.
     *
     * @return iterable<string, array{string, string}> setup SQL, name reported
     */
    public static function existingRelations(): iterable
    {
        $row = "; INSERT INTO cache_items VALUES ('ns:kept', 'stored', NULL, 1)";
        yield 'cache_items exactly as the adapter creates it' => [self::CACHE_ITEMS.$row, 'cache_items'];
        yield 'sessions exactly as expected' => [self::SESSIONS."; INSERT INTO sessions VALUES ('kept', 'stored', 2000000000, 1)", 'sessions'];
        yield 'extra CHECK' => [self::CACHE_ITEMS.$row.'; ALTER TABLE cache_items ADD CONSTRAINT never CHECK (item_time > 0)', 'cache_items'];
        yield 'extra foreign key' => ['CREATE TABLE fk_target (id VARCHAR(255) PRIMARY KEY); '.self::CACHE_ITEMS.'; ALTER TABLE cache_items ADD CONSTRAINT fk FOREIGN KEY (item_id) REFERENCES fk_target (id)', 'cache_items'];
        yield 'extra user trigger' => ['CREATE FUNCTION drop_row() RETURNS trigger LANGUAGE plpgsql AS $$BEGIN RETURN NULL; END$$; '.self::CACHE_ITEMS.'; CREATE TRIGGER drop_it BEFORE INSERT ON cache_items FOR EACH ROW EXECUTE FUNCTION drop_row()', 'cache_items'];
        yield 'extra UNIQUE' => [self::CACHE_ITEMS.$row.'; ALTER TABLE cache_items ADD CONSTRAINT data_uq UNIQUE (item_data)', 'cache_items'];
        yield 'extra index' => [self::CACHE_ITEMS.$row.'; CREATE INDEX extra_idx ON cache_items (item_time)', 'cache_items'];
        yield 'non-default collation' => ["CREATE COLLATION ci (provider = icu, locale = 'und-u-ks-level2', deterministic = false); ".self::CACHE_ITEMS.'; ALTER TABLE cache_items ALTER COLUMN item_id TYPE VARCHAR(255) COLLATE ci', 'cache_items'];
        yield 'UNLOGGED' => [str_replace('CREATE TABLE', 'CREATE UNLOGGED TABLE', self::CACHE_ITEMS).$row, 'cache_items'];
        yield 'different owner' => ['CREATE ROLE migration_test_owner; '.self::CACHE_ITEMS.$row.'; ALTER TABLE cache_items OWNER TO migration_test_owner', 'cache_items'];
        yield 'a view named cache_items' => ['CREATE VIEW cache_items AS SELECT 1 AS item_id', 'cache_items'];
        yield 'an index named sess_lifetime_idx elsewhere' => ['CREATE TABLE other (x INT); CREATE INDEX sess_lifetime_idx ON other (x)', 'sess_lifetime_idx'];
    }

    /**
     * Any existing relation stops the migration before it changes anything,
     * with its own message (not an incidental SQL error); the catalog and
     * the stored rows stay as they were and the version is not recorded.
     */
    #[DataProvider('existingRelations')]
    public function testAnExistingRelationStopsTheMigrationWithoutChanges(string $setup, string $reported): void
    {
        $this->migrateTo(self::CORE);
        try {
            $this->adminScratch()->executeStatement($setup);
            $before = $this->catalog();
            $rows = $this->storedRows();

            [$exit, $output] = $this->console('doctrine:migrations:migrate', '--no-interaction', '--all-or-nothing');

            self::assertNotSame(0, $exit);
            self::assertStringContainsString("Not migrating: {$reported} already exist(s) in schema \"public\"", $output);
            self::assertStringNotContainsString('SQLSTATE', $output, 'the migration stopped itself, not on an SQL error');
            self::assertSame($before, $this->catalog(), 'nothing was created, dropped or altered');
            self::assertSame($rows, $this->storedRows(), 'stored rows are unchanged');
            self::assertSame(0, self::int($this->scratch->fetchOne('SELECT count(*) FROM doctrine_migration_versions WHERE version = ?', [self::SESSIONS_AND_CACHE])));
        } finally {
            if (str_contains($setup, 'migration_test_owner')) {
                $this->scratch->close();
                $this->server()->executeStatement('DROP DATABASE IF EXISTS '.$this->database.' WITH (FORCE)');
                $this->server()->executeStatement('DROP ROLE IF EXISTS migration_test_owner');
                $this->adminScratch = null;
                $this->server()->executeStatement('CREATE DATABASE '.$this->database.' OWNER '.TestDatabase::OWNER);
            }
        }
    }

    /**
     * The documented recovery: rename the existing table by hand, then
     * migrate. The renamed table and its rows are kept for inspection.
     */
    public function testAfterRenamingAnExistingTableTheMigrationRuns(): void
    {
        $this->migrateTo(self::CORE);
        $this->scratch->executeStatement(self::CACHE_ITEMS."; INSERT INTO cache_items VALUES ('ns:kept', 'stored', NULL, 1)");
        self::assertNotSame(0, $this->console('doctrine:migrations:migrate', '--no-interaction', '--all-or-nothing')[0]);

        $this->scratch->executeStatement('ALTER TABLE cache_items RENAME TO cache_items_preexisting');
        $this->scratch->executeStatement('ALTER INDEX cache_items_pkey RENAME TO cache_items_preexisting_pkey');
        [$exit, $output] = $this->console('doctrine:migrations:migrate', '--no-interaction', '--all-or-nothing');

        self::assertSame(0, $exit, $output);
        self::assertSame(['cache_items', 'sessions'], $this->tables(['sessions', 'cache_items']));
        self::assertSame(1, self::int($this->scratch->fetchOne("SELECT count(*) FROM cache_items_preexisting WHERE item_id = 'ns:kept'")));
        self::assertSame(0, self::int($this->scratch->fetchOne('SELECT count(*) FROM cache_items')));
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

    /**
     * Everything an adoption check could miss, for every relation of the
     * schema: kind, persistence, owner, columns (with collation and
     * default), constraints, indexes and user triggers.
     *
     * @return list<array<string, mixed>>
     */
    private function catalog(): array
    {
        return $this->scratch->fetchAllAssociative(<<<'SQL'
            SELECT 'relation' AS kind, c.relname::text AS name, c.relkind::text || ' ' || c.relpersistence::text || ' ' || pg_get_userbyid(c.relowner) AS def
              FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'public'
            UNION ALL
            SELECT 'column', table_name || '.' || column_name, data_type || ' ' || is_nullable || ' ' || coalesce(collation_name, '') || ' ' || coalesce(column_default, '')
              FROM information_schema.columns WHERE table_schema = 'public'
            UNION ALL
            SELECT 'constraint', conrelid::regclass::text || '.' || conname, pg_get_constraintdef(oid)
              FROM pg_constraint WHERE connamespace = 'public'::regnamespace
            UNION ALL
            SELECT 'index', indexname, indexdef FROM pg_indexes WHERE schemaname = 'public'
            UNION ALL
            SELECT 'trigger', tgrelid::regclass::text || '.' || tgname, pg_get_triggerdef(oid)
              FROM pg_trigger WHERE NOT tgisinternal
            ORDER BY 1, 2, 3
            SQL);
    }

    /** @return list<array<string, mixed>> rows of any existing sessions and cache_items tables */
    private function storedRows(): array
    {
        $rows = [];
        foreach ($this->tables(['sessions', 'cache_items']) as $table) {
            // Read as the superuser: a pre-existing table may belong to another role.
            foreach ($this->adminScratch()->fetchAllAssociative("SELECT * FROM {$table} ORDER BY 1") as $row) {
                $rows[] = ['table' => $table] + array_map(static fn (mixed $v): mixed => \is_resource($v) ? stream_get_contents($v) : $v, $row);
            }
        }

        return $rows;
    }

    /**
     * Runs bin/console against the throwaway database.
     *
     * @phpstan-impure
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
    /**
     * The console runs migrations as the schema owner, like the migrate job.
     *
     * @return array<string, string>
     */
    private function consoleEnv(): array
    {
        return [...getenv(), 'APP_ENV' => 'test', 'DATABASE_NAME' => $this->database, ...TestDatabase::ownerProcessEnv()];
    }

    /** The scratch database as the schema owner. */
    private function connect(?DbalConfiguration $configuration = null): Connection
    {
        return TestDatabase::owner($this->database, $configuration);
    }

    /** The bootstrap superuser: creates and drops the scratch databases. */
    private function server(): Connection
    {
        return $this->admin ??= TestDatabase::admin();
    }

    /** The scratch database as the bootstrap superuser: sets up relations an owner could not (roles, foreign owners). */
    private function adminScratch(): Connection
    {
        return $this->adminScratch ??= TestDatabase::admin($this->database);
    }
}
