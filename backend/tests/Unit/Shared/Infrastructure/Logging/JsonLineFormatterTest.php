<?php

declare(strict_types=1);

namespace App\Tests\Unit\Shared\Infrastructure\Logging;

use App\Shared\Infrastructure\Logging\JsonLineFormatter;
use Doctrine\DBAL\Driver\Exception as DriverExceptionInterface;
use Doctrine\DBAL\Exception\UniqueConstraintViolationException;
use Monolog\Level;
use Monolog\LogRecord;
use PHPUnit\Framework\Attributes\DataProvider;
use PHPUnit\Framework\TestCase;

final class JsonLineFormatterTest extends TestCase
{
    public function testARecordIsOneJsonLineWithTheBaselineFields(): void
    {
        $line = $this->format('request completed', ['status' => 200, 'duration_ms' => 1.5], ['request_id' => '0192f0c4-7d1e-7b8a-9f3c-2b4d6e8f0a1c'], 'http');

        self::assertStringEndsWith("\n", $line);
        self::assertSame(1, substr_count($line, "\n"));
        self::assertSame([
            'ts' => '2026-10-21T18:30:00.123Z',
            'level' => 'info',
            'channel' => 'http',
            'message' => 'request completed',
            'request_id' => '0192f0c4-7d1e-7b8a-9f3c-2b4d6e8f0a1c',
            'context' => ['status' => 200, 'duration_ms' => 1.5],
        ], json_decode($line, true, flags: \JSON_THROW_ON_ERROR));
    }

    public function testWithoutARequestTheRequestIdIsNull(): void
    {
        $decoded = json_decode($this->format('migrations applied'), true, flags: \JSON_THROW_ON_ERROR);

        self::assertIsArray($decoded);
        self::assertArrayHasKey('request_id', $decoded);
        self::assertNull($decoded['request_id']);
        self::assertArrayNotHasKey('context', $decoded);
    }

    /**
     * @return iterable<string, array{string, array<string, mixed>, string}>
     */
    public static function secrets(): iterable
    {
        yield 'password key' => ['login failed', ['password' => 'hunter2-value'], 'hunter2-value'];
        yield 'key case and fragment' => ['request', ['headers' => ['Authorization' => 'Bearer abc.def-ghi', 'X-CSRF-Token' => 'csrf-value', 'Set-Cookie' => 'sid=cookie-value']], 'abc.def-ghi'];
        yield 'csrf header' => ['request', ['headers' => ['X-CSRF-Token' => 'csrf-value']], 'csrf-value'];
        yield 'cookie header' => ['request', ['headers' => ['Set-Cookie' => 'sid=cookie-value']], 'cookie-value'];
        yield 'contact e-mail' => ['contact created', ['email' => 'anna@example.com'], 'anna@example.com'];
        yield 'phone' => ['contact created', ['contact' => ['phone' => '+48 600 100 200']], '600 100 200'];
        yield 'session id' => ['session', ['session_id' => 'session-value'], 'session-value'];
        yield 'credential in the message' => ['connect failed: password=hunter2-value host=db', [], 'hunter2-value'];
        yield 'quoted credential in a context string' => ['failed', ['detail' => 'config "secret": "s3cr3t-value"'], 's3cr3t-value'];
        yield 'bearer token in the message' => ['upstream said Authorization: Bearer abc.def-ghi', [], 'abc.def-ghi'];
        yield 'password in a URL' => ['cannot reach pgsql://app:url-pass@db:5432/app', [], 'url-pass'];
        yield 'placeholder of a redacted key' => ['user {email} logged in', ['email' => 'anna@example.com'], 'anna@example.com'];
    }

    /**
     * @param array<string, mixed> $context
     */
    #[DataProvider('secrets')]
    public function testSecretsAndPersonalDataAreRedacted(string $message, array $context, string $secret): void
    {
        $line = $this->format($message, $context);

        self::assertStringNotContainsString($secret, $line);
        self::assertStringContainsString('[redacted]', $line);
        json_decode($line, flags: \JSON_THROW_ON_ERROR);
    }

    public function testPlaceholdersAreFilledFromTheRedactedContext(): void
    {
        $decoded = json_decode($this->format('{count} pending migrations, ready={ready}, reason {reason} {missing}', ['count' => 2, 'ready' => false, 'reason' => null]), true, flags: \JSON_THROW_ON_ERROR);

        self::assertIsArray($decoded);
        self::assertSame('2 pending migrations, ready=false, reason null {missing}', $decoded['message']);
    }

    public function testDatabaseDriverMessagesAreReducedToTheirSqlState(): void
    {
        $driver = new class('SQLSTATE[23505]: Unique violation: 7 ERROR: duplicate key value violates unique constraint "users_email" DETAIL: Key (lower(email))=(anna@example.com) already exists.') extends \RuntimeException implements DriverExceptionInterface {
            public function getSQLState(): string
            {
                return '23505';
            }
        };
        $exception = new UniqueConstraintViolationException($driver, null);
        $wrapped = new \RuntimeException('handler failed', 0, $exception);
        $message = \sprintf('Uncaught PHP Exception %s: "%s" at Connection.php line 1', $exception::class, $exception->getMessage());

        $line = $this->format($message, ['exception' => $wrapped], level: Level::Critical);

        self::assertStringNotContainsString('anna@example.com', $line);
        self::assertStringNotContainsString('duplicate key', $line);
        $decoded = json_decode($line, true, flags: \JSON_THROW_ON_ERROR);
        self::assertIsArray($decoded);
        self::assertSame('critical', $decoded['level']);
        self::assertIsString($decoded['message']);
        self::assertStringContainsString('database error (SQLSTATE 23505)', $decoded['message']);
        self::assertIsArray($decoded['context']);
        self::assertIsArray($decoded['context']['exception']);
        self::assertSame(\RuntimeException::class, $decoded['context']['exception']['class']);
        self::assertSame('handler failed', $decoded['context']['exception']['message']);
        self::assertIsArray($decoded['context']['exception']['previous']);
        self::assertSame(UniqueConstraintViolationException::class, $decoded['context']['exception']['previous']['class']);
        self::assertSame('database error (SQLSTATE 23505)', $decoded['context']['exception']['previous']['message']);
    }

    public function testPdoMessagesAreReducedToTheirSqlState(): void
    {
        $pdo = new \PDOException('SQLSTATE[23505]: Unique violation: DETAIL: Key (email)=(anna@example.com) already exists.');
        $pdo->errorInfo = ['23505', 7, 'duplicate key'];

        $line = $this->format('query failed', ['exception' => new \RuntimeException('wrapped', 0, $pdo)]);

        self::assertStringNotContainsString('anna@example.com', $line);
        self::assertStringContainsString('database error (SQLSTATE 23505)', $line);
    }

    public function testObjectsAreNotSerialised(): void
    {
        $decoded = json_decode($this->format('event', ['user' => new \ArrayObject(['password' => 'x'])]), true, flags: \JSON_THROW_ON_ERROR);

        self::assertIsArray($decoded);
        self::assertSame(['user' => '[ArrayObject]'], $decoded['context']);
    }

    public function testInvalidUtf8StillProducesJson(): void
    {
        $decoded = json_decode($this->format("bad \xC3\x28 byte"), true, flags: \JSON_THROW_ON_ERROR);

        self::assertIsArray($decoded);
        self::assertIsString($decoded['message']);
    }

    /**
     * @param array<string, mixed> $context
     * @param array<string, mixed> $extra
     */
    private function format(string $message, array $context = [], array $extra = [], string $channel = 'app', Level $level = Level::Info): string
    {
        return new JsonLineFormatter()->format(new LogRecord(
            new \DateTimeImmutable('2026-10-21T20:30:00.123+02:00'),
            $channel,
            $level,
            $message,
            $context,
            $extra,
        ));
    }
}
