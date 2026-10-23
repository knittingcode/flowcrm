<?php

declare(strict_types=1);

namespace App\Tests\Support\Http;

use App\Tests\Support\Session\FastCgiResponse;
use App\Tests\Support\Session\FpmServer;
use PHPUnit\Framework\Assert;

/**
 * A browser-like client of the real PHP-FPM (FpmServer): it keeps the
 * cookies the server sets (and drops expired ones), sends the same-origin
 * headers of the SPA, keeps the CSRF token of the last session response in
 * memory and sends it on unsafe requests, and checks every /api/v1 response
 * against the OpenAPI specification.
 *
 * Each client has its own client IP, as the edge would forward it
 * (X-Forwarded-For from REMOTE_ADDR 127.0.0.1, which the test environment trusts), so the IP-based login limits of
 * different tests do not add up. Tests about the IP set it explicitly.
 */
final class ApiClient
{
    public const COOKIE = 'flowcrm_sid';

    /** @var array<string, string> */
    private array $cookies = [];
    private ?string $csrfToken = null;
    private string $clientIp;

    public function __construct(private readonly FpmServer $fpm, ?string $clientIp = null)
    {
        $this->clientIp = $clientIp ?? \sprintf('198.18.%d.%d', random_int(0, 255), random_int(1, 254));
    }

    /** @param array<string, string|null> $params extra FastCGI parameters (HTTP_* headers); null leaves one out */
    public function get(string $uri, array $params = []): ApiResponse
    {
        return $this->send('GET', $uri, $params, null);
    }

    /**
     * A JSON request (Content-Type application/json, the CSRF token when
     * known), or with $raw the body as given and only the $params headers.
     *
     * @param array<string, mixed>|null  $json
     * @param array<string, string|null> $params
     */
    public function post(string $uri, ?array $json = null, array $params = [], ?string $raw = null): ApiResponse
    {
        return $this->unsafe('POST', $uri, $json, $params, $raw);
    }

    /**
     * Like post().
     *
     * @param array<string, mixed>|null  $json
     * @param array<string, string|null> $params
     */
    public function patch(string $uri, ?array $json = null, array $params = [], ?string $raw = null): ApiResponse
    {
        return $this->unsafe('PATCH', $uri, $json, $params, $raw);
    }

    /**
     * Without a body; the CSRF token when known.
     *
     * @param array<string, string|null> $params
     */
    public function delete(string $uri, array $params = []): ApiResponse
    {
        return $this->unsafe('DELETE', $uri, null, $params, null);
    }

    /**
     * Starts an unsafe request with the defaults of post() and returns at
     * once; collect() waits for the responses.
     *
     * @param array<string, mixed>|null $json
     */
    public function dispatch(string $method, string $uri, ?array $json = null): PendingRequest
    {
        [$params, $body] = $this->unsafeRequest($json, [], null);

        return new PendingRequest($this, $method, $uri, $this->fpm->dispatch($method, $uri, $this->cookies, $params + ['HTTP_X_FORWARDED_FOR' => $this->clientIp], $body));
    }

    /**
     * Waits for requests that dispatch() started on the same server.
     *
     * @return list<ApiResponse>
     */
    public static function collect(PendingRequest ...$pending): array
    {
        if ([] === $pending) {
            return [];
        }
        $raw = $pending[0]->client->fpm->collect(array_map(static fn (PendingRequest $p): array => $p->handle, array_values($pending)));
        $responses = [];
        foreach (array_values($pending) as $i => $request) {
            $responses[] = $request->client->receive($request->method, $request->uri, $raw[$i]);
        }

        return $responses;
    }

    public function login(string $email, string $password): ApiResponse
    {
        $response = $this->post('/api/v1/auth/login', ['email' => $email, 'password' => $password]);
        Assert::assertSame(200, $response->status(), 'login failed: '.$response->raw->body);

        return $response;
    }

    public function sessionId(): ?string
    {
        return $this->cookies[self::COOKIE] ?? null;
    }

    public function useSessionId(?string $id): void
    {
        if (null === $id) {
            unset($this->cookies[self::COOKIE]);
        } else {
            $this->cookies[self::COOKIE] = $id;
        }
    }

    public function csrfToken(): ?string
    {
        return $this->csrfToken;
    }

    public function useCsrfToken(?string $token): void
    {
        $this->csrfToken = $token;
    }

    public function clientIp(): string
    {
        return $this->clientIp;
    }

    /**
     * @param array<string, mixed>|null  $json
     * @param array<string, string|null> $params
     */
    private function unsafe(string $method, string $uri, ?array $json, array $params, ?string $raw): ApiResponse
    {
        [$params, $body] = $this->unsafeRequest($json, $params, $raw);

        return $this->send($method, $uri, $params, $body);
    }

    /**
     * @param array<string, mixed>|null  $json
     * @param array<string, string|null> $params
     *
     * @return array{array<string, string|null>, string|null}
     */
    private function unsafeRequest(?array $json, array $params, ?string $raw): array
    {
        $defaults = null === $raw && null !== $json ? ['CONTENT_TYPE' => 'application/json'] : [];
        if (null !== $this->csrfToken) {
            $defaults['HTTP_X_CSRF_TOKEN'] = $this->csrfToken;
        }

        return [$params + $defaults, $raw ?? (null === $json ? null : json_encode($json, \JSON_THROW_ON_ERROR))];
    }

    /** @param array<string, string|null> $params */
    private function send(string $method, string $uri, array $params, ?string $body): ApiResponse
    {
        return $this->receive($method, $uri, $this->fpm->request($method, $uri, $this->cookies, params: $params + ['HTTP_X_FORWARDED_FOR' => $this->clientIp], body: $body));
    }

    private function receive(string $method, string $uri, FastCgiResponse $raw): ApiResponse
    {
        $this->keepCookies($raw);
        OpenApiContract::assertResponse($method, $uri, $raw);
        $response = new ApiResponse($raw);
        if (str_contains((string) $response->header('Content-Type'), 'application/json')) {
            $token = $response->json()['csrfToken'] ?? null;
            if (\is_string($token)) {
                $this->csrfToken = $token;
            }
        }

        return $response;
    }

    private function keepCookies(FastCgiResponse $response): void
    {
        foreach ($response->header('Set-Cookie') as $cookie) {
            $parts = array_map('trim', explode(';', $cookie));
            [$name, $value] = explode('=', array_shift($parts), 2) + [1 => ''];
            $expired = 'deleted' === $value || '' === $value;
            foreach ($parts as $attribute) {
                if (1 === preg_match('/^max-age=(-?\d+)$/i', $attribute, $m) && (int) $m[1] <= 0) {
                    $expired = true;
                }
            }
            if ($expired) {
                unset($this->cookies[$name]);
            } else {
                $this->cookies[$name] = urldecode($value);
            }
        }
    }
}
