<?php

declare(strict_types=1);

namespace App\Tests\Integration\Cache;

use App\Shared\Infrastructure\Cache\RejectSchemaChanges;
use App\Shared\Infrastructure\Cache\SchemaChangeRejected;
use App\Tests\Support\Database\TestDatabase;
use App\Tests\Support\TypedValues;
use Doctrine\DBAL\Connection;
use Doctrine\DBAL\Exception\DriverException;
use Monolog\Handler\TestHandler;
use Monolog\Logger;
use PHPUnit\Framework\Attributes\DataProvider;
use Symfony\Bundle\FrameworkBundle\Test\KernelTestCase;
use Symfony\Component\Cache\Adapter\DoctrineDbalAdapter;

/**
 * The application cache runs on its own connection ("cache" in
 * doctrine.yaml): a failing cache query cannot abort a transaction of the
 * default connection, and the connection refuses schema changes, so the
 * cache adapter cannot create its table before the migration does.
 */
final class CacheConnectionTest extends KernelTestCase
{
    use TypedValues;

    private const IN_FAILED_TRANSACTION = '25P02';
    private const USER = '0192f0c4-7d1e-7b8a-9f3c-00000000ca01';

    public function testTheCacheUsesItsOwnLazyConnection(): void
    {
        $cache = $this->connection('cache');
        $default = $this->connection('default');
        self::assertFalse($cache->isConnected(), 'opened only when the cache is used');

        $adapter = self::getContainer()->get('cache.app');
        self::assertInstanceOf(DoctrineDbalAdapter::class, $adapter);
        self::assertSame($cache, new \ReflectionProperty(DoctrineDbalAdapter::class, 'conn')->getValue($adapter));
        $adapter->getItem('probe');

        self::assertTrue($cache->isConnected());
        self::assertSame('flowcrm_cache', $cache->fetchOne('SHOW application_name'));
        self::assertNotSame(self::int($cache->fetchOne('SELECT pg_backend_pid()')), self::int($default->fetchOne('SELECT pg_backend_pid()')));
    }

    /**
     * @return iterable<string, array{string}>
     */
    public static function schemaChanges(): iterable
    {
        yield 'create' => ['CREATE TABLE cache_guard_other (id INT)'];
        yield 'create, lower case and indented' => ["  \n create table cache_guard_other (id int)"];
        // Only the probe table: if the guard regressed, nothing else is harmed.
        yield 'alter' => ['ALTER TABLE cache_guard_probe ADD COLUMN extra INT'];
        yield 'drop' => ['DROP TABLE cache_guard_probe'];
        yield 'truncate' => ['TRUNCATE cache_guard_probe'];
    }

    #[DataProvider('schemaChanges')]
    public function testTheCacheConnectionRefusesSchemaChanges(string $sql): void
    {
        // The probe table belongs to the owner; the runtime role could not create it.
        $default = TestDatabase::owner();
        $default->executeStatement('CREATE TABLE cache_guard_probe (id INT)');
        $default->executeStatement('INSERT INTO cache_guard_probe VALUES (1)');
        try {
            $this->connection('cache')->executeStatement($sql);
            self::fail('the statement ran');
        } catch (SchemaChangeRejected) {
        } finally {
            $after = $default->fetchAllAssociative("SELECT column_name FROM information_schema.columns WHERE table_name = 'cache_guard_probe'");
            $rows = [] === $after ? 0 : self::int($default->fetchOne('SELECT count(*) FROM cache_guard_probe'));
            $created = self::int($default->fetchOne("SELECT count(*) FROM pg_tables WHERE tablename = 'cache_guard_other'"));
            $default->executeStatement('DROP TABLE IF EXISTS cache_guard_probe');
            $default->executeStatement('DROP TABLE IF EXISTS cache_guard_other');
            $default->close();
        }
        self::assertSame(0, $created, 'no table was created');
        self::assertSame([['column_name' => 'id']], $after, 'the probe table is unchanged');
        self::assertSame(1, $rows, 'its row is still there');
    }

    /**
     * The guard belongs to the cache connection only; the default connection
     * is restricted by the runtime role's privileges instead (ADR-018).
     */
    public function testTheGuardIsRegisteredForTheCacheConnectionOnly(): void
    {
        $guarded = static fn (Connection $c): bool => [] !== array_filter($c->getConfiguration()->getMiddlewares(), static fn (object $m): bool => $m instanceof RejectSchemaChanges);

        self::assertTrue($guarded($this->connection('cache')));
        self::assertFalse($guarded($this->connection('default')));
    }

    public function testACacheFailureDoesNotAbortABusinessTransaction(): void
    {
        $default = $this->connection('default');
        $log = new TestHandler();
        // A pool whose table is missing: every query of it fails.
        $broken = new DoctrineDbalAdapter($this->connection('cache'), 'broken', 0, ['db_table' => 'cache_items_missing']);
        $broken->setLogger(new Logger('cache', [$log]));

        $default->beginTransaction();
        try {
            $this->insertUser($default);

            self::assertSame('computed', $broken->get('key', static fn (): string => 'computed'));

            self::assertSame(1, self::int($default->fetchOne('SELECT count(*) FROM users WHERE id = ?', [self::USER])), 'the transaction goes on');
        } finally {
            $default->rollBack();
        }
        self::assertTrue($log->hasWarningRecords(), 'the cache failure is logged');
        self::assertSame(0, self::int($default->fetchOne("SELECT count(*) FROM pg_tables WHERE tablename = 'cache_items_missing'")), 'and the adapter created no table');
    }

    /**
     * Negative control: the same failure on the default connection (the
     * configuration before the dedicated connection) aborts the business
     * transaction.
     */
    public function testOnTheDefaultConnectionACacheFailureAbortsTheTransaction(): void
    {
        $default = $this->connection('default');
        $broken = new DoctrineDbalAdapter($default, 'broken', 0, ['db_table' => 'cache_items_missing']);
        $broken->setLogger(new Logger('cache', [new TestHandler()]));

        $default->beginTransaction();
        try {
            $this->insertUser($default);
            $broken->get('key', static fn (): string => 'computed');

            $default->fetchOne('SELECT count(*) FROM users WHERE id = ?', [self::USER]);
            self::fail('the transaction was not aborted');
        } catch (DriverException $e) {
            self::assertSame(self::IN_FAILED_TRANSACTION, $e->getSQLState());
        } finally {
            $default->rollBack();
        }
    }

    private function insertUser(Connection $db): void
    {
        $db->executeStatement("INSERT INTO users (id, email, password_hash, display_name, created_at) VALUES (?, 'cache-isolation@example.com', 'h', 'C', now())", [self::USER]);
    }

    private function connection(string $name): Connection
    {
        $connection = self::getContainer()->get("doctrine.dbal.{$name}_connection");
        self::assertInstanceOf(Connection::class, $connection);

        return $connection;
    }
}
