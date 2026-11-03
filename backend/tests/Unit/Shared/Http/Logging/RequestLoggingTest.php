<?php

declare(strict_types=1);

namespace App\Tests\Unit\Shared\Http\Logging;

use App\Shared\Http\Logging\RequestIdProcessor;
use App\Shared\Http\Logging\RequestLogListener;
use App\Shared\Http\RequestId;
use App\Tests\Unit\Shared\Http\Health\RecordingLogger;
use Monolog\Level;
use Monolog\LogRecord;
use PHPUnit\Framework\TestCase;
use Symfony\Component\HttpFoundation\Request;
use Symfony\Component\HttpFoundation\RequestStack;
use Symfony\Component\HttpFoundation\Response;
use Symfony\Component\HttpKernel\Event\ResponseEvent;
use Symfony\Component\HttpKernel\HttpKernelInterface;

final class RequestLoggingTest extends TestCase
{
    public function testTheProcessorAddsTheRequestIdOfTheMainRequest(): void
    {
        $request = Request::create('/api/v1/system/status', server: ['HTTP_X_REQUEST_ID' => '0192F0C4-7D1E-7B8A-9F3C-2B4D6E8F0A1C']);
        $stack = new RequestStack();
        $stack->push($request);

        $record = new RequestIdProcessor($stack)($this->record());

        self::assertSame('0192f0c4-7d1e-7b8a-9f3c-2b4d6e8f0a1c', $record->extra['request_id']);
        self::assertSame(RequestId::of($request), $record->extra['request_id']);
    }

    public function testTheProcessorAddsNothingOutsideARequest(): void
    {
        self::assertSame([], new RequestIdProcessor(new RequestStack())($this->record())->extra);
    }

    public function testACompletedRequestIsLoggedWithoutPathQueryOrHeaders(): void
    {
        $logger = new RecordingLogger();
        $request = Request::create('/api/v1/system/status?token=query-secret', server: ['REQUEST_TIME_FLOAT' => microtime(true) - 0.25, 'HTTP_AUTHORIZATION' => 'Bearer header-secret']);
        $request->attributes->set('_route', 'api_v1_system_status');

        new RequestLogListener($logger)($this->response($request, 503));

        self::assertCount(1, $logger->records);
        [$level, $message, $context] = $logger->records[0];
        self::assertSame('info', $level);
        self::assertSame('request completed', $message);
        self::assertSame('GET', $context['method']);
        self::assertSame('api_v1_system_status', $context['route']);
        self::assertSame(503, $context['status']);
        self::assertIsFloat($context['duration_ms']);
        self::assertGreaterThanOrEqual(250.0, $context['duration_ms']);
        self::assertLessThan(60_000.0, $context['duration_ms']);
        $serialized = serialize($logger->records);
        self::assertStringNotContainsString('query-secret', $serialized);
        self::assertStringNotContainsString('header-secret', $serialized);
        self::assertStringNotContainsString('/api/v1/system/status', $serialized);
    }

    public function testAnUnmatchedRouteIsLoggedWithoutARoute(): void
    {
        $logger = new RecordingLogger();

        new RequestLogListener($logger)($this->response(Request::create('/api/v1/nothing'), 404));

        self::assertNull($logger->records[0][2]['route']);
        self::assertSame(404, $logger->records[0][2]['status']);
    }

    public function testHealthChecksAreLoggedAtDebugLevel(): void
    {
        $logger = new RecordingLogger();
        $request = Request::create('/health/live');
        $request->attributes->set('_route', 'health_live');

        new RequestLogListener($logger)($this->response($request, 200));

        self::assertSame('debug', $logger->records[0][0]);
    }

    public function testSubRequestsAreNotLogged(): void
    {
        $logger = new RecordingLogger();
        $request = Request::create('/api/x');
        $event = new ResponseEvent($this->createStub(HttpKernelInterface::class), $request, HttpKernelInterface::SUB_REQUEST, new Response());

        new RequestLogListener($logger)($event);

        self::assertSame([], $logger->records);
    }

    private function response(Request $request, int $status): ResponseEvent
    {
        return new ResponseEvent($this->createStub(HttpKernelInterface::class), $request, HttpKernelInterface::MAIN_REQUEST, new Response('', $status));
    }

    private function record(): LogRecord
    {
        return new LogRecord(new \DateTimeImmutable(), 'app', Level::Info, 'message');
    }
}
