<?php

declare(strict_types=1);

namespace App\Tests\Integration\Security;

use App\Tests\Support\Http\ApiClient;
use App\Tests\Support\Http\FpmApiTestCase;
use App\Tests\Support\Security\Fixtures;
use PHPUnit\Framework\Attributes\DataProvider;

/**
 * Cross-site request forgery defences over the real PHP-FPM (ADR-019):
 * origin policy, JSON-only bodies and the session-bound token, and their
 * order relative to the firewall (the guard runs first).
 */
final class RequestForgeryTest extends FpmApiTestCase
{
    /**
     * @return iterable<string, array{array<string, string|null>}>
     */
    public static function foreignOrigins(): iterable
    {
        yield 'another site' => [['HTTP_ORIGIN' => 'https://evil.example']];
        yield 'same host, other scheme' => [['HTTP_ORIGIN' => 'https://localhost']];
        yield 'same host, other port' => [['HTTP_ORIGIN' => 'http://localhost:8081']];
        yield 'opaque origin (sandboxed frame)' => [['HTTP_ORIGIN' => 'null']];
        yield 'no Origin, foreign Referer' => [['HTTP_ORIGIN' => null, 'HTTP_REFERER' => 'https://evil.example/page']];
        yield 'neither Origin nor Referer' => [['HTTP_ORIGIN' => null]];
        yield 'cross-site fetch metadata' => [['HTTP_SEC_FETCH_SITE' => 'cross-site']];
        yield 'same-site fetch metadata' => [['HTTP_SEC_FETCH_SITE' => 'same-site']];
    }

    /**
     * @param array<string, string|null> $headers
     */
    #[DataProvider('foreignOrigins')]
    public function testLoginFromAnotherOriginIsRefusedBeforeAuthentication(array $headers): void
    {
        $user = $this->fixtures->user('origin');
        $client = $this->client();

        $response = $client->post('/api/v1/auth/login', ['email' => $user->email, 'password' => $user->password], $headers);

        self::assertSame(403, $response->status());
        self::assertSame('/problems/csrf-invalid', $response->problem());
        self::assertNull($client->sessionId(), 'no session: the guard ran before json_login');
        self::assertSame($response->header('X-Request-Id'), $response->value('requestId'), 'the refusal carries its request ID');
    }

    /**
     * @param array<string, string|null> $headers
     */
    #[DataProvider('foreignOrigins')]
    public function testAuthenticatedUnsafeRequestsFromAnotherOriginAreRefusedEvenWithTheToken(array $headers): void
    {
        $user = $this->fixtures->user('foreign');
        $client = $this->client();
        $client->login($user->email, $user->password);

        $response = $client->post('/api/v1/me/password', ['currentPassword' => $user->password, 'newPassword' => 'a forged new passphrase'], $headers);

        self::assertSame(403, $response->status());
        self::assertSame('/problems/csrf-invalid', $response->problem());
        $this->client()->login($user->email, $user->password);
    }

    public function testASameOriginRefererReplacesAMissingOrigin(): void
    {
        $user = $this->fixtures->user('referer');
        $client = $this->client();

        $response = $client->post('/api/v1/auth/login', ['email' => $user->email, 'password' => $user->password], ['HTTP_ORIGIN' => null, 'HTTP_REFERER' => 'http://localhost/login?returnTo=%2F']);

        self::assertSame(200, $response->status());
    }

    public function testTheSessionTokenIsRequiredForAuthenticatedUnsafeRequests(): void
    {
        $user = $this->fixtures->user('token');
        $client = $this->client();
        $client->login($user->email, $user->password);
        $other = $this->client();
        $other->login($this->fixtures->user('other')->email, Fixtures::PASSWORD);
        $valid = $client->csrfToken();

        foreach (['missing' => null, 'empty' => '', 'forged' => str_repeat('x', 43), 'another session\'s' => $other->csrfToken()] as $case => $token) {
            $client->useCsrfToken(null);
            $params = null === $token ? [] : ['HTTP_X_CSRF_TOKEN' => $token];
            $response = $client->post('/api/v1/me/password', ['currentPassword' => $user->password, 'newPassword' => 'a forged new passphrase'], $params);
            self::assertSame(403, $response->status(), $case);
            self::assertSame('/problems/csrf-invalid', $response->problem(), $case);
        }

        $client->useCsrfToken($valid);
        self::assertSame(204, $client->post('/api/v1/me/password', ['currentPassword' => $user->password, 'newPassword' => 'the real new passphrase'])->status());
    }

    /** Safe methods never need the token; reading with the session cookie works. */
    public function testSafeRequestsNeedNoToken(): void
    {
        $user = $this->fixtures->user('safe');
        $client = $this->client();
        $client->login($user->email, $user->password);
        $client->useCsrfToken(null);

        self::assertSame(200, $client->get('/api/v1/me', ['HTTP_ORIGIN' => 'https://evil.example'])->status());
    }

    /**
     * Bodies that an HTML form or a CORS-simple request can send are refused
     * (415) before anything else, also for login.
     *
     * @return iterable<string, array{string}>
     */
    public static function simpleContentTypes(): iterable
    {
        yield 'form' => ['application/x-www-form-urlencoded'];
        yield 'multipart' => ['multipart/form-data; boundary=x'];
        yield 'text' => ['text/plain'];
    }

    #[DataProvider('simpleContentTypes')]
    public function testBodiesMustBeJson(string $contentType): void
    {
        $user = $this->fixtures->user('media');
        $client = $this->client();

        $login = $client->post('/api/v1/auth/login', raw: 'email='.urlencode($user->email).'&password='.urlencode($user->password), params: ['CONTENT_TYPE' => $contentType]);
        self::assertSame(415, $login->status());
        self::assertSame('/problems/unsupported-media-type', $login->problem());
        self::assertSame($login->header('X-Request-Id'), $login->value('requestId'));
        self::assertNull($client->sessionId());

        $client->login($user->email, $user->password);
        $change = $client->post('/api/v1/me/password', raw: '{"currentPassword":"x","newPassword":"y"}', params: ['CONTENT_TYPE' => $contentType, 'HTTP_X_CSRF_TOKEN' => (string) $client->csrfToken()]);
        self::assertSame(415, $change->status());
    }

    /** Without a logged-in session, an unsafe request to a protected route is a 401 (the firewall), not a CSRF error. */
    public function testAnonymousUnsafeRequestsAreUnauthenticated(): void
    {
        $response = $this->client()->post('/api/v1/me/password', ['currentPassword' => 'x', 'newPassword' => 'long enough password']);

        self::assertSame(401, $response->status());
        self::assertSame('/problems/unauthenticated', $response->problem());
    }

    public function testMalformedJsonIsABadRequest(): void
    {
        $user = $this->fixtures->user('malformed');
        $client = $this->client();
        $client->login($user->email, $user->password);

        foreach (['{"currentPassword":', '[]', '"text"', '{"currentPassword":1,"newPassword":"long enough password"}'] as $body) {
            $response = $client->post('/api/v1/me/password', raw: $body, params: ['CONTENT_TYPE' => 'application/json', 'HTTP_X_CSRF_TOKEN' => (string) $client->csrfToken()]);
            self::assertContains($response->status(), [400, 422], $body);
        }
        $login = $this->client()->post('/api/v1/auth/login', raw: '{"email":', params: ['CONTENT_TYPE' => 'application/json']);
        self::assertSame(400, $login->status());
        $missing = $this->client()->post('/api/v1/auth/login', ['email' => $user->email]);
        self::assertSame(400, $missing->status());
    }

    /** The token is only in the JSON body: never in a header or cookie. */
    public function testTheTokenTravelsOnlyInTheBody(): void
    {
        $user = $this->fixtures->user('travel');
        $client = $this->client();
        $response = $client->login($user->email, $user->password);
        $token = $response->string('csrfToken');

        foreach ($response->raw->headers as [$name, $value]) {
            self::assertStringNotContainsString($token, $value, $name);
        }
        self::assertSame([ApiClient::COOKIE], array_map(static fn (string $c): string => explode('=', $c, 2)[0], $response->raw->header('Set-Cookie')), 'no CSRF cookie');
        // The answer carries a masked token (a new mask on every response),
        // so the value itself is not what the session stores.
        self::assertStringNotContainsString($token, (string) $this->sessionData($client->sessionId()));
    }
}
