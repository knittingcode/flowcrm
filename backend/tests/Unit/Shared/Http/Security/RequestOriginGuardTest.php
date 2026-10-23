<?php

declare(strict_types=1);

namespace App\Tests\Unit\Shared\Http\Security;

use App\Shared\Http\Problem\ProblemException;
use App\Shared\Http\Security\RequestOriginGuard;
use PHPUnit\Framework\Attributes\DataProvider;
use PHPUnit\Framework\TestCase;
use Psr\Log\NullLogger;
use Symfony\Component\HttpFoundation\Request;
use Symfony\Component\HttpFoundation\Session\Session;
use Symfony\Component\HttpFoundation\Session\Storage\MockArraySessionStorage;
use Symfony\Component\HttpKernel\Event\RequestEvent;
use Symfony\Component\HttpKernel\HttpKernelInterface;
use Symfony\Component\Security\Csrf\CsrfToken;
use Symfony\Component\Security\Csrf\CsrfTokenManagerInterface;

final class RequestOriginGuardTest extends TestCase
{
    /** @return iterable<string, array{string, string, array<string, string>, string, int|null}> */
    public static function requests(): iterable
    {
        $json = ['CONTENT_TYPE' => 'application/json'];
        yield 'safe method, foreign origin' => ['GET', '/api/v1/me', ['HTTP_ORIGIN' => 'https://evil.example'], '', null];
        yield 'not under /api' => ['POST', '/health/live', [], '', null];
        yield 'same origin' => ['POST', '/api/v1/auth/login', ['HTTP_ORIGIN' => 'http://localhost'] + $json, '{}', null];
        yield 'same origin with charset' => ['POST', '/api/v1/auth/login', ['HTTP_ORIGIN' => 'http://localhost', 'CONTENT_TYPE' => 'application/json; charset=utf-8'], '{}', null];
        yield 'same-origin referer' => ['POST', '/api/v1/auth/login', ['HTTP_REFERER' => 'http://localhost/login'] + $json, '{}', null];
        yield 'origin without port vs non-default port' => ['POST', '/api/v1/auth/login', ['HTTP_ORIGIN' => 'http://localhost', 'HTTP_HOST' => 'localhost:8083'] + $json, '{}', 403];
        yield 'matching non-default port' => ['POST', '/api/v1/auth/login', ['HTTP_ORIGIN' => 'http://localhost:8083', 'HTTP_HOST' => 'localhost:8083'] + $json, '{}', null];
        yield 'foreign origin' => ['POST', '/api/v1/auth/login', ['HTTP_ORIGIN' => 'https://evil.example'] + $json, '{}', 403];
        yield 'origin that only starts like ours' => ['POST', '/api/v1/auth/login', ['HTTP_ORIGIN' => 'http://localhost.evil.example'] + $json, '{}', 403];
        yield 'foreign referer' => ['POST', '/api/v1/auth/login', ['HTTP_REFERER' => 'http://evil.example/http://localhost/'] + $json, '{}', 403];
        yield 'unparsable referer' => ['POST', '/api/v1/auth/login', ['HTTP_REFERER' => 'not a url'] + $json, '{}', 403];
        yield 'no origin at all' => ['POST', '/api/v1/auth/login', $json, '{}', 403];
        yield 'cross-site fetch' => ['POST', '/api/v1/auth/login', ['HTTP_ORIGIN' => 'http://localhost', 'HTTP_SEC_FETCH_SITE' => 'cross-site'] + $json, '{}', 403];
        yield 'same-origin fetch' => ['POST', '/api/v1/auth/login', ['HTTP_ORIGIN' => 'http://localhost', 'HTTP_SEC_FETCH_SITE' => 'same-origin'] + $json, '{}', null];
        yield 'form body' => ['POST', '/api/v1/auth/login', ['HTTP_ORIGIN' => 'http://localhost', 'CONTENT_TYPE' => 'application/x-www-form-urlencoded'], 'a=b', 415];
        yield 'text body' => ['POST', '/api/v1/auth/login', ['HTTP_ORIGIN' => 'http://localhost', 'CONTENT_TYPE' => 'text/plain'], '{}', 415];
        yield 'body without type' => ['POST', '/api/v1/auth/login', ['HTTP_ORIGIN' => 'http://localhost'], '{}', 415];
        yield 'empty body, no type' => ['POST', '/api/v1/auth/logout', ['HTTP_ORIGIN' => 'http://localhost'], '', null];
        yield 'DELETE is unsafe too' => ['DELETE', '/api/v1/x', ['HTTP_ORIGIN' => 'https://evil.example'], '', 403];
        yield 'https origin behind https' => ['POST', '/api/v1/auth/login', ['HTTP_ORIGIN' => 'https://localhost', 'HTTPS' => 'on'] + $json, '{}', null];
    }

    /** @param array<string, string> $server */
    #[DataProvider('requests')]
    public function testTheOriginAndMediaTypePolicy(string $method, string $path, array $server, string $body, ?int $status): void
    {
        $request = Request::create($path, $method, server: $server, content: $body);
        if (!isset($server['CONTENT_TYPE'])) {
            // Request::create() adds a form type to unsafe requests; a browser's fetch() does not.
            $request->headers->remove('Content-Type');
        }
        $request->attributes->set('_route', 'api_v1_auth_login');

        self::assertSame($status, $this->outcome($request, tokenValid: false));
    }

    public function testAnAuthenticatedSessionNeedsAValidToken(): void
    {
        foreach ([[null, false, 403], ['wrong', false, 403], ['right', true, null]] as [$token, $valid, $status]) {
            $request = $this->authenticated($token);
            self::assertSame($status, $this->outcome($request, $valid), (string) $token);
        }
    }

    public function testLoginIsExemptFromTheTokenButNotFromTheOrigin(): void
    {
        $request = $this->authenticated(null);
        $request->attributes->set('_route', 'api_v1_auth_login');
        self::assertNull($this->outcome($request, tokenValid: false));

        $request->headers->set('Origin', 'https://evil.example');
        self::assertSame(403, $this->outcome($request, tokenValid: false));
    }

    public function testAnAnonymousSessionNeedsNoToken(): void
    {
        $request = $this->authenticated(null);
        $request->getSession()->remove('_security_api');

        self::assertNull($this->outcome($request, tokenValid: false));
    }

    private function authenticated(?string $token): Request
    {
        $request = Request::create('/api/v1/me/password', 'POST', server: ['HTTP_ORIGIN' => 'http://localhost', 'CONTENT_TYPE' => 'application/json'], content: '{}');
        $request->attributes->set('_route', 'api_v1_me_password');
        $session = new Session(new MockArraySessionStorage());
        $session->set('_security_api', 'serialized token');
        $request->setSession($session);
        $request->cookies->set($session->getName(), 'id');
        if (null !== $token) {
            $request->headers->set('X-CSRF-Token', $token);
        }

        return $request;
    }

    private function outcome(Request $request, bool $tokenValid): ?int
    {
        $tokens = $this->createStub(CsrfTokenManagerInterface::class);
        $tokens->method('isTokenValid')->willReturnCallback(static fn (CsrfToken $t): bool => $tokenValid && 'api' === $t->getId());
        $guard = new RequestOriginGuard($tokens, new NullLogger(), '_security_api', ['api_v1_auth_login']);
        try {
            $guard(new RequestEvent($this->createStub(HttpKernelInterface::class), $request, HttpKernelInterface::MAIN_REQUEST));
        } catch (ProblemException $e) {
            return $e->getStatusCode();
        }

        return null;
    }
}
