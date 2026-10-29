<?php

declare(strict_types=1);

namespace App\Tests\Integration\Security;

use App\Tests\Support\Http\ApiResponse;
use App\Tests\Support\Http\FpmApiTestCase;
use App\Tests\Support\Session\FpmServer;
use App\Tests\Support\Session\SeparateConnection;

/**
 * A request with a session cookie whose session cannot be read, because the
 * database is not available or another request of the same session holds
 * its lock for longer than lock_timeout, answers a 500 internal-error
 * problem document without details (docs/architecture/sessions-and-cache.md)
 * and changes nothing. The specification must declare that answer: ApiClient
 * checks every answer against backend/openapi.yaml.
 *
 * Covered are all /api/v1 routes that read the session of such a request:
 * GET /auth/session, /me and the organization reads (CurrentUser through the
 * lazy firewall), POST /auth/login (the firewall's context listener runs
 * before json_login), and POST /auth/logout and /me/password
 * (RequestOriginGuard reads the session for the CSRF check before the
 * firewall). The status route does not read the session and reports the
 * database itself.
 */
final class SessionStoreOutageTest extends FpmApiTestCase
{
    public function testEveryRouteThatReadsTheSessionAnswersAnInternalErrorWithoutDetailsWithoutTheDatabase(): void
    {
        $user = $this->fixtures->user('outage');
        $organizationId = $this->fixtures->organization('outage');
        $organization = $organizationId->toRfc4122();
        $membership = $this->fixtures->member($organizationId, $user, 'ADMIN')->toRfc4122();
        $client = $this->client();
        $client->login($user->email, $user->password);
        $sessionId = $client->sessionId();
        self::assertNotNull($sessionId);

        $unavailable = new FpmServer(['DATABASE_HOST' => 'db-unavailable.invalid']);
        $unavailable->start();
        try {
            $outage = $this->client($client->clientIp(), $unavailable);
            $outage->useSessionId($sessionId);
            $outage->useCsrfToken($client->csrfToken());
            /** @var list<array{0: 'GET'|'POST', 1: string, 2: array<string, string>|null}> $requests */
            $requests = [
                ['GET', '/api/v1/auth/session', null],
                ['GET', '/api/v1/me', null],
                ['GET', "/api/v1/organizations/$organization", null],
                ['GET', "/api/v1/organizations/$organization/members", null],
                ['GET', "/api/v1/organizations/$organization/members/$membership", null],
                ['POST', '/api/v1/auth/login', ['email' => $user->email, 'password' => $user->password]],
                ['POST', '/api/v1/me/password', ['currentPassword' => $user->password, 'newPassword' => 'outage-new-password-7f3a']],
                // Last: a logout that answered 500 must not have ended the session.
                ['POST', '/api/v1/auth/logout', null],
            ];
            foreach ($requests as [$method, $uri, $body]) {
                $route = "$method $uri";
                $response = 'GET' === $method ? $outage->get($uri) : $outage->post($uri, $body);
                self::assertSame(500, $response->status(), $route);
                self::assertInternalErrorWithoutDetails($response, $uri, $sessionId, $route);
                self::assertSame($sessionId, $outage->sessionId(), "$route: the session cookie is neither expired nor replaced");
            }
            self::assertSame(503, $outage->get('/api/v1/system/status')->status(), 'the status route reports the database itself');
        } finally {
            $unavailable->remove();
        }

        // Nothing was ended or changed: the session and the password still work.
        self::assertSame(200, $client->get('/api/v1/me')->status(), 'the session is still valid');
        self::assertSame(200, $this->client()->login($user->email, $user->password)->status(), 'the password is unchanged');
    }

    /**
     * The lock-timeout half of the SessionUnavailable response, on a route
     * of the specification (FpmSessionTest covers it on the test-only probe
     * route): the request waits at least lock_timeout (5 s) and gives up.
     *
     * Only the lower bound is asserted. The total duration on a firewall
     * route is not yet measured: review suggests the context listener starts
     * the session again on the way out and waits a second time (about 2x
     * lock_timeout). That is tracked as a backlog item to measure in CI;
     * FpmServer's request timeout (15 s) still bounds this test.
     */
    public function testARouteWaitingLongerThanTheLockTimeoutForTheSessionAnswersAnInternalErrorWithoutDetails(): void
    {
        $user = $this->fixtures->user('locked');
        $client = $this->client();
        $client->login($user->email, $user->password);
        $sessionId = $client->sessionId();
        self::assertNotNull($sessionId);

        $holder = SeparateConnection::open();
        $holder->beginTransaction();
        try {
            $holder->prepare('SELECT sess_data FROM sessions WHERE sess_id = ? FOR UPDATE')->execute([$sessionId]);
            $start = microtime(true);
            $response = $client->get('/api/v1/me');
            $waited = microtime(true) - $start;

            self::assertGreaterThanOrEqual(5.0, $waited, 'it waited at least the lock timeout (lock_timeout 5 s)');
            self::assertSame(500, $response->status());
            self::assertInternalErrorWithoutDetails($response, '/api/v1/me', $sessionId, 'GET /api/v1/me');
            self::assertSame($sessionId, $client->sessionId(), 'the session cookie is neither expired nor replaced');
        } finally {
            $holder->rollBack();
        }

        self::assertSame(200, $client->get('/api/v1/me')->status(), 'the session is still valid');
    }

    /**
     * Exactly the members of the Problem schema with the generic values of
     * ProblemResponse, and nothing of the exception: no driver, host, user,
     * SQL state, class, file or session ID.
     */
    private static function assertInternalErrorWithoutDetails(ApiResponse $response, string $uri, string $sessionId, string $route): void
    {
        self::assertSame('/problems/internal-error', $response->problem(), $route);
        $body = $response->json();
        self::assertSame(['type', 'title', 'status', 'instance', 'requestId'], array_keys($body), "$route: only the members of Problem");
        self::assertSame('Internal Server Error', $body['title'], $route);
        self::assertSame(500, $body['status'], $route);
        self::assertSame($uri, $body['instance'], $route);
        self::assertSame($response->header('X-Request-Id'), $body['requestId'], "$route: the request ID of the log record");
        $details = [$sessionId, 'db-unavailable', 'SQLSTATE', '55P03', 'PDO', 'pgsql', 'flowcrm_sessions', 'sessions', 'lock', 'Exception', '.php', self::string($_SERVER['DATABASE_USER'] ?? 'flowcrm')];
        foreach ($details as $detail) {
            self::assertStringNotContainsString($detail, $response->raw->body, "$route: no details");
        }
    }
}
