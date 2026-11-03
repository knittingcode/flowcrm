<?php

declare(strict_types=1);

namespace App\Tests\Integration\Session;

use App\Tests\Support\Session\SeparateConnection;
use App\Tests\Support\TypedValues;
use Doctrine\DBAL\ArrayParameterType;
use Doctrine\DBAL\Connection;
use Doctrine\DBAL\ParameterType;
use Symfony\Bundle\FrameworkBundle\Test\KernelTestCase;
use Symfony\Component\HttpFoundation\Session\Storage\Handler\PdoSessionHandler;

/**
 * The configured session handler against the real PostgreSQL, driven the
 * way PHP's session module drives it (open, validateId/read, write, close).
 * A second handler on its own connection plays a concurrent request.
 */
final class PdoSessionHandlerTest extends KernelTestCase
{
    use TypedValues;

    private const LOCK_NOT_AVAILABLE = '55P03';

    /** @var list<string> */
    private array $ids = [];

    protected function setUp(): void
    {
        // As NativeSessionStorage sets it for every request.
        ini_set('session.use_strict_mode', '1');
        ini_set('session.gc_maxlifetime', '1800');
    }

    protected function tearDown(): void
    {
        if ([] !== $this->ids) {
            $this->db()->executeStatement('DELETE FROM sessions WHERE sess_id IN (?)', [$this->ids], [ArrayParameterType::STRING]);
        }
        parent::tearDown();
    }

    public function testTheConfiguredHandlerLocksTransactionallyOnItsOwnConnection(): void
    {
        $handler = $this->configured();
        $property = static fn (string $name): mixed => new \ReflectionProperty(PdoSessionHandler::class, $name)->getValue($handler);

        self::assertSame(PdoSessionHandler::LOCK_TRANSACTIONAL, $property('lockMode'));
        self::assertSame('sessions', $property('table'));
        self::assertIsString($property('dsn'), 'a DSN, not the Doctrine connection: the lock transaction stays separate');
        self::assertStringContainsString('application_name=flowcrm_sessions', (string) $property('dsn'));
        self::assertStringNotContainsString('password', (string) $property('dsn'));
    }

    /**
     * The session connection waits at most 5 s for a lock; Doctrine's
     * connections keep PostgreSQL's default (no limit).
     */
    public function testOnlyTheSessionConnectionHasALockTimeout(): void
    {
        $handler = $this->configured();
        $handler->open('', 'flowcrm_sid');
        try {
            $pdo = new \ReflectionProperty(PdoSessionHandler::class, 'pdo')->getValue($handler);
            self::assertInstanceOf(\PDO::class, $pdo);
            foreach (['lock_timeout' => '5s', 'application_name' => 'flowcrm_sessions'] as $setting => $value) {
                $statement = $pdo->query('SHOW '.$setting);
                self::assertInstanceOf(\PDOStatement::class, $statement);
                self::assertSame($value, $statement->fetchColumn(), $setting);
            }
        } finally {
            $handler->close();
        }

        foreach (['default', 'cache'] as $name) {
            $connection = self::getContainer()->get("doctrine.dbal.{$name}_connection");
            self::assertInstanceOf(Connection::class, $connection);
            self::assertSame('0', $connection->fetchOne('SHOW lock_timeout'), $name);
        }
    }

    public function testWriteReadAndDestroy(): void
    {
        $id = $this->newId();
        $data = "binary\0data\xff with a NUL byte";
        $handler = $this->configured();

        $this->roundTrip($handler, $id, $data);

        $handler->open('', 'flowcrm_sid');
        self::assertTrue($handler->validateId($id));
        self::assertSame($data, $handler->read($id));
        self::assertTrue($handler->destroy($id));
        $handler->close();
        self::assertSame(0, $this->rows($id));
    }

    public function testAnUnknownIdIsInvalidAndCreatesNoRow(): void
    {
        $id = $this->newId();
        $handler = $this->configured();

        $handler->open('', 'flowcrm_sid');
        self::assertFalse($handler->validateId($id));
        $handler->close();

        self::assertSame(0, $this->rows($id));
    }

    public function testAnExpiredSessionReadsAsEmptyAndIsInvalid(): void
    {
        $id = $this->newId();
        $this->db()->insert('sessions', ['sess_id' => $id, 'sess_data' => 'stale', 'sess_lifetime' => time() - 1, 'sess_time' => time() - 1801], ['sess_data' => ParameterType::LARGE_OBJECT]);
        $handler = $this->configured();

        $handler->open('', 'flowcrm_sid');
        self::assertFalse($handler->validateId($id));
        self::assertSame('', $handler->read($id));
        $handler->close();
    }

    public function testGarbageCollectionDeletesOnlyExpiredSessions(): void
    {
        $expired = $this->newId();
        $valid = $this->newId();
        $this->db()->insert('sessions', ['sess_id' => $expired, 'sess_data' => 'x', 'sess_lifetime' => time() - 60, 'sess_time' => time() - 1860], ['sess_data' => ParameterType::LARGE_OBJECT]);
        $this->db()->insert('sessions', ['sess_id' => $valid, 'sess_data' => 'x', 'sess_lifetime' => time() + 60, 'sess_time' => time() - 1740], ['sess_data' => ParameterType::LARGE_OBJECT]);
        $handler = $this->configured();

        $handler->open('', 'flowcrm_sid');
        $handler->gc(1800);
        self::assertSame(1, $this->rows($expired), 'deleted at close, after the request');
        $handler->close();

        self::assertSame(0, $this->rows($expired));
        self::assertSame(1, $this->rows($valid));
    }

    public function testASecondRequestWaitsForTheSessionLock(): void
    {
        $id = $this->newId();
        $first = $this->configured();
        $this->roundTrip($first, $id, 'n=1');

        $first->open('', 'flowcrm_sid');
        try {
            self::assertSame('n=1', $first->read($id));

            // While the first request holds the row lock, the second cannot read.
            $second = $this->handler(PdoSessionHandler::LOCK_TRANSACTIONAL, lockTimeoutMs: 300);
            $second->open('', 'flowcrm_sid');
            try {
                $second->read($id);
                self::fail('the second read did not wait for the lock');
            } catch (\PDOException $e) {
                self::assertSame(self::LOCK_NOT_AVAILABLE, $e->getCode(), $e->getMessage());
            }

            $first->write($id, 'n=2');
        } finally {
            $first->close();
        }

        $third = $this->handler(PdoSessionHandler::LOCK_TRANSACTIONAL, lockTimeoutMs: 300);
        $third->open('', 'flowcrm_sid');
        self::assertSame('n=2', $third->read($id), 'after the first request ends, the next one sees its write');
        $third->close();
    }

    /** Negative control: without the lock, concurrent requests lose an update. */
    public function testWithoutLockingAConcurrentUpdateIsLost(): void
    {
        $id = $this->newId();
        $this->roundTrip($this->configured(), $id, 'n=1');

        $a = $this->handler(PdoSessionHandler::LOCK_NONE);
        $b = $this->handler(PdoSessionHandler::LOCK_NONE);
        $a->open('', 'flowcrm_sid');
        $b->open('', 'flowcrm_sid');
        self::assertSame('n=1', $a->read($id));
        self::assertSame('n=1', $b->read($id), 'not blocked');
        $a->write($id, 'n=2');
        $a->close();
        $b->write($id, 'n=2');
        $b->close();

        $check = $this->configured();
        $check->open('', 'flowcrm_sid');
        self::assertSame('n=2', $check->read($id), 'two increments, one result: the update was lost');
        $check->close();
    }

    private function roundTrip(PdoSessionHandler $handler, string $id, string $data): void
    {
        $handler->open('', 'flowcrm_sid');
        $handler->read($id);
        self::assertTrue($handler->write($id, $data));
        $handler->close();
        self::assertSame(1, $this->rows($id));
    }

    private function configured(): PdoSessionHandler
    {
        $handler = self::getContainer()->get(PdoSessionHandler::class);
        self::assertInstanceOf(PdoSessionHandler::class, $handler);

        return $handler;
    }

    /** A handler on a new connection, as another PHP-FPM worker would have. */
    private function handler(int $lockMode, ?int $lockTimeoutMs = null): PdoSessionHandler
    {
        $pdo = SeparateConnection::open();
        if (null !== $lockTimeoutMs) {
            $pdo->exec(\sprintf("SET lock_timeout = '%dms'", $lockTimeoutMs));
        }

        return new PdoSessionHandler($pdo, ['lock_mode' => $lockMode]);
    }

    private function newId(): string
    {
        $id = bin2hex(random_bytes(16));
        $this->ids[] = $id;

        return $id;
    }

    private function rows(string $id): int
    {
        return self::int($this->db()->fetchOne('SELECT count(*) FROM sessions WHERE sess_id = ?', [$id]));
    }

    private function db(): Connection
    {
        $db = self::getContainer()->get('doctrine.dbal.default_connection');
        self::assertInstanceOf(Connection::class, $db);

        return $db;
    }
}
