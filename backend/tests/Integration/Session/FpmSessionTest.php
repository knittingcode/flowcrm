<?php

declare(strict_types=1);

namespace App\Tests\Integration\Session;

use App\Tests\Support\Session\FastCgiResponse;
use App\Tests\Support\Session\FpmServer;
use App\Tests\Support\TypedValues;
use Doctrine\DBAL\ArrayParameterType;
use Doctrine\DBAL\Connection;
use PHPUnit\Framework\Attributes\DataProvider;
use Symfony\Bundle\FrameworkBundle\Test\KernelTestCase;

/**
 * Sessions end to end: the real PHP-FPM (FpmServer) with the configured
 * PdoSessionHandler against the real PostgreSQL. The session is used only
 * by the test-only SessionProbeController.
 */
final class FpmSessionTest extends KernelTestCase
{
    use TypedValues;

    private const COOKIE = 'flowcrm_sid';
    /** 32 characters of 4 bits: 128 bits from PHP's CSPRNG. */
    private const SESSION_ID = '/^[0-9a-f]{32}$/';

    private static FpmServer $fpm;

    /** @var list<string> session IDs this test saw, removed afterwards */
    private array $seen = [];

    public static function setUpBeforeClass(): void
    {
        self::$fpm = new FpmServer();
        self::$fpm->start();
    }

    public static function tearDownAfterClass(): void
    {
        self::$fpm->remove();
    }

    protected function tearDown(): void
    {
        $log = self::$fpm->log();
        foreach ($this->seen as $id) {
            self::assertStringNotContainsString($id, $log, 'a session ID was logged');
        }
        self::assertDoesNotMatchRegularExpression('/PHP (Warning|Notice|Deprecated|Fatal error)/', $log);
        if ([] !== $this->seen) {
            $this->db()->executeStatement('DELETE FROM sessions WHERE sess_id IN (?)', [$this->seen], [ArrayParameterType::STRING]);
        }
        parent::tearDown();
    }

    public function testStatelessRoutesNeitherSetACookieNorStoreASession(): void
    {
        $before = $this->sessionCount();
        foreach (['/health/live', '/health/ready', '/api/v1/system/status', '/api/v1/does-not-exist'] as $uri) {
            $response = self::$fpm->request('GET', $uri);
            self::assertSame([], $response->header('Set-Cookie'), $uri);
        }
        // Reading an empty session starts it, but nothing is stored or sent.
        $response = self::$fpm->request('GET', '/api/_test/session');
        self::assertSame(['n' => null], $response->json());
        self::assertSame([], $response->header('Set-Cookie'));
        self::assertSame($before, $this->sessionCount());
    }

    public function testANewSessionGetsAStrongIdAndASafeCookie(): void
    {
        $response = self::$fpm->request('POST', '/api/_test/session/increment');
        $id = $this->idFrom($response);

        self::assertMatchesRegularExpression(self::SESSION_ID, $id);
        self::assertSame(['n' => 1], $response->json());
        self::assertStringNotContainsString($id, $response->body);
        $cookie = $response->setCookies(self::COOKIE)[0];
        self::assertSame(['path=/', 'httponly', 'samesite=lax'], $this->attributes($cookie));

        $row = $this->row($id);
        self::assertNotNull($row, 'the session is stored');
        self::assertEqualsWithDelta(time() + 1800, $row['sess_lifetime'], 5, 'expires after the idle lifetime');
        self::assertEqualsWithDelta(time(), $row['sess_time'], 5);
    }

    public function testTheCookieIsSecureOverHttps(): void
    {
        $response = self::$fpm->request('POST', '/api/_test/session/increment', https: true);
        $this->idFrom($response);

        self::assertSame(['path=/', 'secure', 'httponly', 'samesite=lax'], $this->attributes($response->setCookies(self::COOKIE)[0]));
    }

    public function testTheSessionPersistsAcrossRequestsAndAPhpFpmRestart(): void
    {
        $id = $this->idFrom(self::$fpm->request('POST', '/api/_test/session/increment'));
        $second = self::$fpm->request('POST', '/api/_test/session/increment', [self::COOKIE => $id]);
        self::assertSame(['n' => 2], $second->json());
        self::assertSame([], $second->setCookies(self::COOKIE), 'a known session keeps its ID');

        self::$fpm->restart();

        self::assertSame(['n' => 2], self::$fpm->request('GET', '/api/_test/session', [self::COOKIE => $id])->json());
    }

    public function testAnUnknownSessionIdIsNeverAdopted(): void
    {
        $chosen = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
        $this->seen[] = $chosen;

        $response = self::$fpm->request('POST', '/api/_test/session/increment', [self::COOKIE => $chosen]);

        $id = $this->idFrom($response);
        self::assertNotSame($chosen, $id, 'session fixation: the attacker-chosen ID is replaced');
        self::assertSame(['n' => 1], $response->json());
        self::assertNull($this->row($chosen));
    }

    /**
     * @return iterable<string, array{string}>
     */
    public static function malformedIds(): iterable
    {
        yield 'path traversal' => ['../../etc/passwd'];
        yield 'quote and semicolon' => ["x';DROP TABLE sessions;--"];
        yield 'too long' => [str_repeat('a', 300)];
        yield 'empty' => [''];
        yield 'non-ASCII' => ['zażółć'];
    }

    #[DataProvider('malformedIds')]
    public function testAMalformedSessionIdGetsANewSession(string $malformed): void
    {
        $response = self::$fpm->request('POST', '/api/_test/session/increment', [self::COOKIE => rawurlencode($malformed)]);

        self::assertSame(200, $response->status, $response->body);
        self::assertSame(['n' => 1], $response->json());
        self::assertMatchesRegularExpression(self::SESSION_ID, $this->idFrom($response));
    }

    public function testAnExpiredSessionIsNotRestored(): void
    {
        $id = $this->idFrom(self::$fpm->request('POST', '/api/_test/session/increment'));
        $this->db()->executeStatement('UPDATE sessions SET sess_lifetime = ? WHERE sess_id = ?', [time() - 1, $id]);

        self::assertSame(['n' => null], self::$fpm->request('GET', '/api/_test/session', [self::COOKIE => $id])->json());
        $response = self::$fpm->request('POST', '/api/_test/session/increment', [self::COOKIE => $id]);
        self::assertSame(['n' => 1], $response->json(), 'the expired data is gone');
        self::assertNotSame($id, $this->idFrom($response), 'an expired session ID is not reused');
    }

    public function testMigrateIssuesANewIdKeepsTheDataAndDeletesTheOldRow(): void
    {
        $old = $this->idFrom(self::$fpm->request('POST', '/api/_test/session/increment'));

        $response = self::$fpm->request('POST', '/api/_test/session/migrate', [self::COOKIE => $old]);

        $new = $this->idFrom($response);
        self::assertNotSame($old, $new);
        self::assertSame(['n' => 1], $response->json());
        self::assertNull($this->row($old), 'the old ID cannot be replayed');
        self::assertSame(['n' => 1], self::$fpm->request('GET', '/api/_test/session', [self::COOKIE => $new])->json());
        self::assertSame(['n' => null], self::$fpm->request('GET', '/api/_test/session', [self::COOKIE => $old])->json());
    }

    public function testInvalidateDeletesTheSessionAndExpiresTheCookie(): void
    {
        $id = $this->idFrom(self::$fpm->request('POST', '/api/_test/session/increment'));

        $response = self::$fpm->request('POST', '/api/_test/session/invalidate', [self::COOKIE => $id]);

        self::assertSame(204, $response->status);
        self::assertNull($this->row($id));
        $cleared = $response->setCookies(self::COOKIE);
        self::assertNotSame([], $cleared, 'the cookie is removed');
        self::assertSame('deleted', $response->cookieValue(self::COOKIE));
        self::assertContains('max-age=0', $this->attributes(end($cleared)));
        self::assertSame(['n' => null], self::$fpm->request('GET', '/api/_test/session', [self::COOKIE => $id])->json());
    }

    public function testConcurrentRequestsOfOneSessionAreSerialised(): void
    {
        $id = $this->idFrom(self::$fpm->request('POST', '/api/_test/session/increment'));

        $start = microtime(true);
        $responses = self::$fpm->concurrently([
            ['POST', '/api/_test/session/increment?pause_ms=500', [self::COOKIE => $id]],
            ['POST', '/api/_test/session/increment?pause_ms=500', [self::COOKIE => $id]],
        ]);
        $elapsed = microtime(true) - $start;

        $counts = array_map(static fn (FastCgiResponse $r): mixed => $r->json()['n'] ?? null, $responses);
        sort($counts);
        self::assertSame([2, 3], $counts, 'no lost update');
        self::assertSame(['n' => 3], self::$fpm->request('GET', '/api/_test/session', [self::COOKIE => $id])->json());
        self::assertGreaterThanOrEqual(1.0, $elapsed, 'the second request waited for the first');
    }

    public function testWithoutTheDatabaseOnlySessionRoutesFailAndTheyFailSafely(): void
    {
        $fpm = new FpmServer(['DATABASE_HOST' => 'db-unavailable.invalid']);
        $fpm->start();
        try {
            $live = $fpm->request('GET', '/health/live');
            self::assertSame(200, $live->status);
            self::assertSame([], $live->header('Set-Cookie'));

            $response = $fpm->request('POST', '/api/_test/session/increment');
            self::assertSame(500, $response->status);
            self::assertSame(['application/problem+json'], $response->header('Content-Type'));
            self::assertSame([], $response->header('Set-Cookie'));
            foreach (['db-unavailable', 'pgsql', 'flowcrm_sessions', 'SQLSTATE', 'PDO', self::string($_SERVER['DATABASE_USER'] ?? 'flowcrm')] as $detail) {
                self::assertStringNotContainsString($detail, $response->body);
            }
        } finally {
            $fpm->remove();
        }
    }

    private function idFrom(FastCgiResponse $response): string
    {
        self::assertSame(200, $response->status, $response->body);
        $id = $response->cookieValue(self::COOKIE);
        self::assertNotNull($id, 'the response sets the session cookie');
        $this->seen[] = $id;

        return $id;
    }

    /** @return list<string> the cookie attributes after name=value, lower-cased */
    private function attributes(string $setCookie): array
    {
        return array_map(static fn (string $a): string => strtolower(trim($a)), \array_slice(explode(';', $setCookie), 1));
    }

    /** @return array{sess_lifetime: int, sess_time: int}|null */
    private function row(string $id): ?array
    {
        $row = $this->db()->fetchAssociative('SELECT sess_lifetime, sess_time FROM sessions WHERE sess_id = ?', [$id]);
        if (false === $row) {
            return null;
        }

        return ['sess_lifetime' => self::int($row['sess_lifetime']), 'sess_time' => self::int($row['sess_time'])];
    }

    private function sessionCount(): int
    {
        return self::int($this->db()->fetchOne('SELECT count(*) FROM sessions'));
    }

    private function db(): Connection
    {
        $db = self::getContainer()->get('doctrine.dbal.default_connection');
        self::assertInstanceOf(Connection::class, $db);

        return $db;
    }
}
