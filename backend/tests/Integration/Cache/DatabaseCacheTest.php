<?php

declare(strict_types=1);

namespace App\Tests\Integration\Cache;

use App\Tests\Support\TypedValues;
use Doctrine\DBAL\Connection;
use Doctrine\DBAL\DriverManager;
use PHPUnit\Framework\Attributes\DataProvider;
use Psr\Cache\InvalidArgumentException;
use Psr\Log\AbstractLogger;
use Symfony\Bundle\FrameworkBundle\Test\KernelTestCase;
use Symfony\Component\Cache\Adapter\AdapterInterface;
use Symfony\Component\Cache\Adapter\DoctrineDbalAdapter;
use Symfony\Contracts\Cache\CacheInterface;
use Symfony\Contracts\Cache\ItemInterface;

/**
 * cache.app and the pools based on it, stored by DoctrineDbalAdapter in
 * the cache_items table of the real PostgreSQL. test.cache.pool_a and
 * test.cache.pool_b exist only in the test environment.
 */
final class DatabaseCacheTest extends KernelTestCase
{
    use TypedValues;

    private string $key;

    protected function setUp(): void
    {
        // Unique per test, so runs never see each other's items.
        $this->key = 'k'.bin2hex(random_bytes(8));
    }

    protected function tearDown(): void
    {
        $this->db()->executeStatement('DELETE FROM cache_items WHERE item_id LIKE ?', ['%'.$this->key.'%']);
        parent::tearDown();
    }

    public function testTheApplicationCacheIsTheDatabaseAdapter(): void
    {
        self::assertInstanceOf(DoctrineDbalAdapter::class, $this->pool('cache.app'));
        self::assertInstanceOf(DoctrineDbalAdapter::class, $this->pool('test.cache.pool_a'));
    }

    public function testAnItemIsStoredInCacheItemsAndReadBack(): void
    {
        $pool = $this->pool('test.cache.pool_a');
        $computed = 0;
        $compute = static function (ItemInterface $item) use (&$computed): array {
            ++$computed;
            $item->expiresAfter(300);

            return ['value' => 42];
        };

        self::assertSame(['value' => 42], $pool->get($this->key, $compute));
        self::assertSame(['value' => 42], $this->pool('test.cache.pool_a')->get($this->key, $compute));
        self::assertSame(1, $computed, 'the second read is a hit');

        $rows = $this->rows();
        self::assertCount(1, $rows);
        self::assertSame(300, self::int($rows[0]['item_lifetime']));
        self::assertEqualsWithDelta(time(), self::int($rows[0]['item_time']), 5);
    }

    public function testAnExpiredItemIsAMissAndIsRemovedWhenRead(): void
    {
        $pool = $this->pool('test.cache.pool_a');
        $pool->get($this->key, static function (ItemInterface $item): string {
            $item->expiresAfter(1);

            return 'old';
        });
        sleep(2);

        self::assertSame('new', $pool->get($this->key, static fn (): string => 'new'));
        self::assertSame(['new'], array_map(static fn (array $r): mixed => $r['value'], $this->decoded()));
    }

    public function testDeletingAnItemRemovesItsRow(): void
    {
        $pool = $this->pool('test.cache.pool_a');
        $pool->get($this->key, static fn (): string => 'v');

        self::assertTrue($pool->delete($this->key));
        self::assertSame([], $this->rows());
        self::assertSame('again', $pool->get($this->key, static fn (): string => 'again'));
    }

    public function testPoolsHaveSeparateNamespaces(): void
    {
        $a = $this->pool('test.cache.pool_a');
        $b = $this->pool('test.cache.pool_b');
        $a->get($this->key, static fn (): string => 'from a');
        $b->get($this->key, static fn (): string => 'from b');

        self::assertSame('from a', $a->get($this->key, static fn (): string => 'recomputed'));
        self::assertSame('from b', $b->get($this->key, static fn (): string => 'recomputed'));
        $ids = array_column($this->rows(), 'item_id');
        self::assertCount(2, $ids);
        self::assertNotSame(explode(':', self::string($ids[0]))[0], explode(':', self::string($ids[1]))[0], 'different prefixes');

        self::assertTrue($a->clear());
        self::assertSame('from b', $b->get($this->key, static fn (): string => 'recomputed'), 'clearing a leaves b');
        self::assertSame('recomputed', $a->get($this->key, static fn (): string => 'recomputed'));
    }

    public function testClearingAPoolTouchesNoOtherTable(): void
    {
        $before = $this->otherTables();
        $pool = $this->pool('test.cache.pool_a');
        $pool->get($this->key, static fn (): string => 'v');

        self::assertTrue($pool->clear());

        self::assertSame($before, $this->otherTables());
    }

    public function testPruningRemovesOnlyExpiredItems(): void
    {
        $pool = $this->pool('test.cache.pool_a');
        self::assertInstanceOf(DoctrineDbalAdapter::class, $pool);
        $pool->get($this->key.'-expired', static function (ItemInterface $item): string {
            $item->expiresAfter(1);

            return 'x';
        });
        $pool->get($this->key.'-valid', static function (ItemInterface $item): string {
            $item->expiresAfter(300);

            return 'y';
        });
        sleep(2);

        self::assertTrue($pool->prune());

        self::assertSame([$this->key.'-valid'], array_map(static fn (array $r): string => (string) preg_replace('/^[^:]*:/', '', self::string($r['item_id'])), $this->rows()));
    }

    /**
     * @return iterable<string, array{string}>
     */
    public static function reservedKeys(): iterable
    {
        foreach (['{', '}', '(', ')', '/', '\\', '@', ':'] as $char) {
            yield $char => ['user'.$char.'input'];
        }
    }

    /**
     * Keys are validated, so request input cannot address another namespace.
     */
    #[DataProvider('reservedKeys')]
    public function testKeysWithReservedCharactersAreRejected(string $key): void
    {
        $this->expectException(InvalidArgumentException::class);
        $this->pool('test.cache.pool_a')->get($key, static fn (): string => 'v');
    }

    public function testWithAnUnreachableDatabaseEveryReadIsALoggedMiss(): void
    {
        $logger = new class extends AbstractLogger {
            /** @var list<string> */
            public array $messages = [];

            public function log($level, \Stringable|string $message, array $context = []): void
            {
                $this->messages[] = (\is_string($level) ? $level : 'unknown').' '.$message;
            }
        };
        // Configured like doctrine.yaml: with server_version, the adapter
        // knows the platform without connecting, so failures are caught.
        $unreachable = DriverManager::getConnection([
            'driver' => 'pdo_pgsql',
            'host' => 'db-unavailable.invalid',
            'dbname' => 'flowcrm',
            'user' => 'flowcrm',
            'password' => 'not-the-password',
            'serverVersion' => '18',
        ]);
        $pool = new DoctrineDbalAdapter($unreachable, 'ns');
        $pool->setLogger($logger);

        self::assertSame('computed', $pool->get($this->key, static fn (): string => 'computed'));
        self::assertSame('computed again', $pool->get($this->key, static fn (): string => 'computed again'), 'nothing was stored');
        self::assertNotSame([], $logger->messages, 'the failure is logged');
        foreach ($logger->messages as $message) {
            self::assertStringStartsWith('warning ', $message);
        }
    }

    private function pool(string $id): CacheInterface&AdapterInterface
    {
        $pool = self::getContainer()->get($id);
        self::assertInstanceOf(CacheInterface::class, $pool);
        self::assertInstanceOf(AdapterInterface::class, $pool);

        return $pool;
    }

    /** @return list<array<string, mixed>> */
    private function rows(): array
    {
        return $this->db()->fetchAllAssociative('SELECT item_id, item_lifetime, item_time FROM cache_items WHERE item_id LIKE ? ORDER BY item_id', ['%'.$this->key.'%']);
    }

    /** @return list<array{value: mixed}> */
    private function decoded(): array
    {
        $values = [];
        foreach ($this->db()->fetchFirstColumn('SELECT item_data FROM cache_items WHERE item_id LIKE ?', ['%'.$this->key.'%']) as $data) {
            $values[] = ['value' => unserialize(self::string($data))];
        }

        return $values;
    }

    /** @return array<string, int> */
    private function otherTables(): array
    {
        $counts = [];
        foreach (['users', 'organizations', 'memberships', 'pipelines', 'pipeline_stages', 'audit_events', 'sessions', 'doctrine_migration_versions'] as $table) {
            $counts[$table] = self::int($this->db()->fetchOne('SELECT count(*) FROM '.$table));
        }

        return $counts;
    }

    private function db(): Connection
    {
        $db = self::getContainer()->get('doctrine.dbal.default_connection');
        self::assertInstanceOf(Connection::class, $db);

        return $db;
    }
}
