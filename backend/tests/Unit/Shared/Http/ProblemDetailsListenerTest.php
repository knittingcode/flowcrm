<?php

declare(strict_types=1);

namespace App\Tests\Unit\Shared\Http;

use App\Shared\Http\Problem\ProblemDetailsListener;
use App\Shared\Http\RequestId;
use App\Tests\Unit\Shared\Http\Health\RecordingLogger;
use PHPUnit\Framework\Attributes\DataProvider;
use PHPUnit\Framework\TestCase;
use Symfony\Component\HttpFoundation\Request;
use Symfony\Component\HttpKernel\Event\ExceptionEvent;
use Symfony\Component\HttpKernel\Exception\MethodNotAllowedHttpException;
use Symfony\Component\HttpKernel\Exception\NotFoundHttpException;
use Symfony\Component\HttpKernel\HttpKernelInterface;

final class ProblemDetailsListenerTest extends TestCase
{
    public function testNotFoundUnderApiIsAProblemDocument(): void
    {
        $event = $this->dispatch('/api/v1/unknown', new NotFoundHttpException('No route found for "GET /api/v1/unknown"'));
        $response = $event->getResponse();

        self::assertNotNull($response);
        self::assertSame(404, $response->getStatusCode());
        self::assertSame('application/problem+json', $response->headers->get('Content-Type'));
        $body = json_decode((string) $response->getContent(), true, flags: \JSON_THROW_ON_ERROR);
        self::assertIsArray($body);
        self::assertSame('/problems/not-found', $body['type']);
        self::assertSame('Not Found', $body['title']);
        self::assertSame(404, $body['status']);
        self::assertSame('/api/v1/unknown', $body['instance']);
        self::assertSame('0192f0c4-7d1e-7b8a-9f3c-2b4d6e8f0a1c', $body['requestId']);
        self::assertStringNotContainsString('No route found', (string) $response->getContent());
    }

    public function testMethodNotAllowedKeepsTheAllowHeader(): void
    {
        $response = $this->dispatch('/api/v1/system/status', new MethodNotAllowedHttpException(['GET']))->getResponse();

        self::assertNotNull($response);
        self::assertSame(405, $response->getStatusCode());
        self::assertSame('GET', $response->headers->get('Allow'));
    }

    public function testUnexpectedErrorsRevealNothingAndAreLogged(): void
    {
        $logger = new RecordingLogger();
        $response = $this->dispatch('/api/v1/system/status', new \RuntimeException('connection to db:5432 failed, password=secret'), $logger)->getResponse();

        self::assertNotNull($response);
        self::assertSame(500, $response->getStatusCode());
        self::assertStringNotContainsString('db:5432', (string) $response->getContent());
        self::assertStringNotContainsString('secret', (string) $response->getContent());
        self::assertStringContainsString('db:5432', $logger->lines());
    }

    /** @return iterable<string, array{string}> */
    public static function nonApiPaths(): iterable
    {
        yield 'health' => ['/health/ready'];
        yield 'prefix lookalike' => ['/apix/v1'];
        yield 'root' => ['/'];
    }

    #[DataProvider('nonApiPaths')]
    public function testOtherPathsAreLeftToTheFramework(string $path): void
    {
        self::assertNull($this->dispatch($path, new NotFoundHttpException())->getResponse());
    }

    private function dispatch(string $path, \Throwable $exception, ?RecordingLogger $logger = null): ExceptionEvent
    {
        $request = Request::create($path);
        $request->headers->set(RequestId::HEADER, '0192F0C4-7D1E-7B8A-9F3C-2B4D6E8F0A1C');
        $event = new ExceptionEvent($this->createStub(HttpKernelInterface::class), $request, HttpKernelInterface::MAIN_REQUEST, $exception);
        new ProblemDetailsListener($logger ?? new RecordingLogger())($event);

        return $event;
    }
}
