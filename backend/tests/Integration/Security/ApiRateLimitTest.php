<?php

declare(strict_types=1);

namespace App\Tests\Integration\Security;

use App\Tests\Support\Http\ApiClient;
use App\Tests\Support\Http\FpmApiTestCase;
use App\Tests\Support\Security\TestUser;
use Symfony\Component\RateLimiter\LimiterInterface;
use Symfony\Component\RateLimiter\RateLimiterFactoryInterface;

/**
 * The per-user API limit of FCRM-002 NFR-007 (600 requests per minute, then
 * 429 with Retry-After) over the real PHP-FPM, with the state in PostgreSQL
 * (ADR-019, UserRateLimitListener).
 */
final class ApiRateLimitTest extends FpmApiTestCase
{
    public function testTheSixHundredFirstRequestOfAMinuteIsRefused(): void
    {
        $user = $this->fixtures->user('busy');
        $client = $this->logIn($user);

        for ($i = 1; $i <= 600; ++$i) {
            $response = $client->get('/api/v1/me');
            if (200 !== $response->status()) {
                self::fail("request $i: ".$response->status());
            }
        }
        $limited = $client->get('/api/v1/me');

        self::assertSame(429, $limited->status());
        self::assertSame('/problems/too-many-requests', $limited->problem());
        $retryAfter = (int) $limited->header('Retry-After');
        self::assertGreaterThanOrEqual(1, $retryAfter);
        self::assertLessThanOrEqual(60, $retryAfter);
        self::assertSame($limited->header('X-Request-Id'), $limited->value('requestId'));
    }

    /** One user's limit is theirs alone; a limited user can still look at the session and log out. */
    public function testTheLimitIsPerUserAndNeverBlocksLogout(): void
    {
        $user = $this->fixtures->user('limited');
        $other = $this->fixtures->user('unaffected');
        $client = $this->logIn($user);
        $this->limiter($user)->consume(600);

        self::assertSame(429, $client->get('/api/v1/me')->status());
        self::assertSame(200, $this->logIn($other)->get('/api/v1/me')->status(), 'another user is not affected');
        self::assertSame(200, $client->get('/api/v1/auth/session')->status(), 'the session probe is not limited');
        self::assertSame(204, $client->post('/api/v1/auth/logout')->status(), 'logout is never limited');
    }

    /**
     * Only authenticated requests to routes that require a login count: not
     * the public routes, not anonymous requests and not unsafe requests the
     * request-origin guard refused (nobody else can use up a user's budget).
     */
    public function testOnlyTheUsersOwnAuthenticatedRequestsCount(): void
    {
        $user = $this->fixtures->user('counted');
        $client = $this->logIn($user);
        self::assertSame(600, $this->remaining($user), 'the login is not counted');

        $client->get('/api/v1/me');
        $client->get('/api/v1/me');
        self::assertSame(598, $this->remaining($user));

        $client->get('/api/v1/auth/session');
        $client->get('/api/v1/system/status');
        $forged = $client->post('/api/v1/me/password', ['currentPassword' => $user->password, 'newPassword' => 'a forged new passphrase'], ['HTTP_ORIGIN' => 'https://evil.example']);
        self::assertSame(403, $forged->status());
        $anonymous = $this->client()->get('/api/v1/me');
        self::assertSame(401, $anonymous->status());
        self::assertSame(598, $this->remaining($user));
    }

    private function logIn(TestUser $user): ApiClient
    {
        $client = $this->client();
        $client->login($user->email, $user->password);

        return $client;
    }

    private function remaining(TestUser $user): int
    {
        return $this->limiter($user)->consume(0)->getRemainingTokens();
    }

    private function limiter(TestUser $user): LimiterInterface
    {
        $factory = self::getContainer()->get('flowcrm.rate_limiter.api_user');
        \assert($factory instanceof RateLimiterFactoryInterface);

        return $factory->create($user->id->toRfc4122());
    }
}
