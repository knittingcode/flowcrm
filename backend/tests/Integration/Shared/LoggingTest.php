<?php

declare(strict_types=1);

namespace App\Tests\Integration\Shared;

use Doctrine\DBAL\Driver\Exception as DriverExceptionInterface;
use Doctrine\DBAL\Exception\UniqueConstraintViolationException;
use Monolog\Handler\TestHandler;
use Symfony\Bundle\FrameworkBundle\Test\WebTestCase;
use Symfony\Component\EventDispatcher\EventDispatcherInterface;
use Symfony\Component\HttpFoundation\Request;
use Symfony\Component\HttpFoundation\RequestStack;
use Symfony\Component\HttpKernel\Event\ExceptionEvent;
use Symfony\Component\HttpKernel\HttpKernelInterface;
use Symfony\Component\HttpKernel\KernelEvents;

/**
 * The configured logging pipeline (processors, formatter, framework error
 * listener) on the booted kernel. The test environment writes the
 * formatted records to Monolog's in-memory handler.
 */
final class LoggingTest extends WebTestCase
{
    public function testARequestIsLoggedWithTheRequestIdOfTheResponse(): void
    {
        $client = self::createClient();
        $client->request('GET', '/api/v1/does-not-exist', server: ['HTTP_X_REQUEST_ID' => '0192f0c4-7d1e-7b8a-9f3c-2b4d6e8f0a1c']);

        self::assertResponseStatusCodeSame(404);
        $body = json_decode((string) $client->getResponse()->getContent(), true, flags: \JSON_THROW_ON_ERROR);
        self::assertIsArray($body);
        self::assertSame('0192f0c4-7d1e-7b8a-9f3c-2b4d6e8f0a1c', $body['requestId']);

        $lines = $this->decode($this->formatted());
        $completed = $this->only($lines, 'request completed');
        self::assertSame('http', $completed['channel']);
        self::assertSame('info', $completed['level']);
        self::assertSame('0192f0c4-7d1e-7b8a-9f3c-2b4d6e8f0a1c', $completed['request_id']);
        self::assertSame(['method' => 'GET', 'route' => null, 'status' => 404], array_intersect_key((array) $completed['context'], ['method' => 1, 'route' => 1, 'status' => 1]));

        $error = $this->only($lines, 'Uncaught PHP Exception');
        self::assertSame('info', $error['level'], 'an unknown route is not an error');
        self::assertSame('0192f0c4-7d1e-7b8a-9f3c-2b4d6e8f0a1c', $error['request_id']);
    }

    public function testHealthChecksAreDebugRecordsOnTheirChannel(): void
    {
        $client = self::createClient();
        $client->request('GET', '/health/live');

        $completed = $this->only($this->decode($this->formatted()), 'request completed');
        self::assertSame('debug', $completed['level']);
        self::assertSame('health_live', ((array) $completed['context'])['route']);
    }

    public function testADatabaseErrorIsLoggedWithoutItsDataAndCorrelatesWithTheProblemDocument(): void
    {
        $client = self::createClient();
        $container = self::getContainer();
        $request = Request::create('/api/v1/accounts', 'POST', server: ['HTTP_X_REQUEST_ID' => '0192f0c4-7d1e-7b8a-9f3c-2b4d6e8f0a1d']);
        $requests = $container->get('request_stack');
        self::assertInstanceOf(RequestStack::class, $requests);
        $requests->push($request);

        $driver = new class('SQLSTATE[23505]: Unique violation: 7 ERROR: duplicate key value violates unique constraint DETAIL: Key (lower(email))=(anna@example.com) already exists.') extends \RuntimeException implements DriverExceptionInterface {
            public function getSQLState(): string
            {
                return '23505';
            }
        };
        $event = new ExceptionEvent($client->getKernel(), $request, HttpKernelInterface::MAIN_REQUEST, new UniqueConstraintViolationException($driver, null));
        $dispatcher = $container->get('event_dispatcher');
        self::assertInstanceOf(EventDispatcherInterface::class, $dispatcher);
        $dispatcher->dispatch($event, KernelEvents::EXCEPTION);

        $response = $event->getResponse();
        self::assertNotNull($response);
        self::assertSame(500, $response->getStatusCode());
        $body = json_decode((string) $response->getContent(), true, flags: \JSON_THROW_ON_ERROR);
        self::assertIsArray($body);
        self::assertSame('0192f0c4-7d1e-7b8a-9f3c-2b4d6e8f0a1d', $body['requestId']);

        $raw = implode('', $this->formatted());
        self::assertStringNotContainsString('anna@example.com', $raw);
        self::assertStringNotContainsString('duplicate key', $raw);
        $error = $this->only($this->decode($this->formatted()), 'Uncaught PHP Exception');
        self::assertSame('critical', $error['level']);
        self::assertSame('0192f0c4-7d1e-7b8a-9f3c-2b4d6e8f0a1d', $error['request_id']);
        self::assertIsString($error['message']);
        self::assertStringContainsString('database error (SQLSTATE 23505)', $error['message']);
    }

    /**
     * @return list<string>
     */
    private function formatted(): array
    {
        $handler = self::getContainer()->get('monolog.handler.main');
        self::assertInstanceOf(TestHandler::class, $handler);

        $lines = [];
        foreach ($handler->getRecords() as $record) {
            self::assertIsString($record->formatted);
            $lines[] = $record->formatted;
        }

        return $lines;
    }

    /**
     * @param list<string> $formatted
     *
     * @return list<array<mixed>>
     */
    private function decode(array $formatted): array
    {
        $lines = [];
        foreach ($formatted as $line) {
            self::assertStringEndsWith("\n", $line);
            $decoded = json_decode($line, true, flags: \JSON_THROW_ON_ERROR);
            self::assertIsArray($decoded);
            self::assertSame(['ts', 'level', 'channel', 'message', 'request_id'], \array_slice(array_keys($decoded), 0, 5));
            /* @var array<string, mixed> $decoded */
            $lines[] = $decoded;
        }

        return $lines;
    }

    /**
     * @param list<array<mixed>> $lines
     *
     * @return array<mixed>
     */
    private function only(array $lines, string $messagePrefix): array
    {
        $matches = array_values(array_filter($lines, static fn (array $line): bool => \is_string($line['message']) && str_starts_with($line['message'], $messagePrefix)));
        self::assertCount(1, $matches, $messagePrefix);

        return $matches[0];
    }
}
