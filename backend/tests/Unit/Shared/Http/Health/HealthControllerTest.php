<?php

declare(strict_types=1);

namespace App\Tests\Unit\Shared\Http\Health;

use App\Shared\Application\Health\ReadinessCheck;
use App\Shared\Application\Health\ReadinessResult;
use App\Shared\Http\Health\HealthController;
use PHPUnit\Framework\TestCase;
use Psr\Log\AbstractLogger;

final class HealthControllerTest extends TestCase
{
    public function testLiveDoesNotConsultReadiness(): void
    {
        $check = new FakeReadiness(static fn (): ReadinessResult => throw new \LogicException('must not be called'));
        $response = new HealthController($check, new RecordingLogger())->live();

        self::assertSame(200, $response->getStatusCode());
        self::assertSame('{"status":"live"}', $response->getContent());
        self::assertSame(0, $check->calls);
    }

    public function testReadyWhenTheCheckPasses(): void
    {
        $response = new HealthController(new FakeReadiness(static fn (): ReadinessResult => ReadinessResult::ready()), new RecordingLogger())->ready();

        self::assertSame(200, $response->getStatusCode());
        self::assertSame('{"status":"ready"}', $response->getContent());
        self::assertStringContainsString('no-store', (string) $response->headers->get('Cache-Control'));
    }

    public function testNotReadyHidesTheReason(): void
    {
        $logger = new RecordingLogger();
        $check = new FakeReadiness(static fn (): ReadinessResult => ReadinessResult::notReady('migrations not current (1 pending, 0 unknown)'));
        $response = new HealthController($check, $logger)->ready();

        self::assertSame(503, $response->getStatusCode());
        self::assertSame('{"status":"not-ready"}', $response->getContent());
        self::assertStringContainsString('1 pending', $logger->lines());
    }

    public function testUnreachableDependencyIsNotReadyWithoutDetails(): void
    {
        $logger = new RecordingLogger();
        $check = new FakeReadiness(static fn (): ReadinessResult => throw new \RuntimeException('SQLSTATE[08006] could not connect to server db:5432 password=secret'));
        $response = new HealthController($check, $logger)->ready();

        self::assertSame(503, $response->getStatusCode());
        self::assertSame('{"status":"not-ready"}', $response->getContent());
        self::assertStringNotContainsString('db:5432', (string) $response->getContent());
        self::assertStringContainsString('could not connect', $logger->lines());
    }
}

final class FakeReadiness implements ReadinessCheck
{
    public int $calls = 0;

    /** @param \Closure(): ReadinessResult $result */
    public function __construct(private readonly \Closure $result)
    {
    }

    public function check(): ReadinessResult
    {
        ++$this->calls;

        return ($this->result)();
    }
}

final class RecordingLogger extends AbstractLogger
{
    /** @var list<string> */
    private array $lines = [];

    public function log($level, \Stringable|string $message, array $context = []): void
    {
        $replace = [];
        foreach ($context as $key => $value) {
            $replace['{'.$key.'}'] = \is_scalar($value) ? (string) $value : '';
        }
        $this->lines[] = strtr((string) $message, $replace);
    }

    public function lines(): string
    {
        return implode("\n", $this->lines);
    }
}
