<?php

declare(strict_types=1);

namespace App\Tests\Integration\Security;

use App\Tests\Support\Security\Fixtures;
use Doctrine\DBAL\Connection;
use Monolog\Handler\TestHandler;
use Symfony\Bundle\FrameworkBundle\KernelBrowser;
use Symfony\Bundle\FrameworkBundle\Test\WebTestCase;

/**
 * Security events go to the log as structured records with pseudonyms:
 * never an e-mail address, a password, a token or an IP address
 * (ADR-019, FCRM-002 NFR-012 and NFR-050).
 */
final class SecurityLoggingTest extends WebTestCase
{
    public function testLoginEventsAreLoggedWithoutPersonalData(): void
    {
        $client = self::createClient();
        $client->disableReboot();
        $user = Fixtures::from(self::getContainer())->user('logged');
        $server = ['CONTENT_TYPE' => 'application/json', 'HTTP_ORIGIN' => 'http://localhost', 'REMOTE_ADDR' => '127.0.0.1', 'HTTP_X_FORWARDED_FOR' => '203.0.113.77'];

        // The in-memory handler is reset between requests: collect after each.
        $client->request('POST', '/api/v1/auth/login', server: $server, content: json_encode(['email' => $user->email, 'password' => 'a wrong password'], \JSON_THROW_ON_ERROR));
        self::assertResponseStatusCodeSame(401);
        $records = $this->records();
        $client->request('POST', '/api/v1/auth/login', server: $server, content: json_encode(['email' => $user->email, 'password' => $user->password], \JSON_THROW_ON_ERROR));
        self::assertResponseStatusCodeSame(200);
        $records = [...$records, ...$this->records()];
        $requestId = '0192f0c4-7d1e-7b8a-9f3c-2b4d6e8f0a1c';
        $client->request('POST', '/api/v1/auth/logout', server: ['CONTENT_TYPE' => 'application/json', 'HTTP_ORIGIN' => 'https://evil.example', 'HTTP_X_REQUEST_ID' => $requestId]);
        self::assertResponseStatusCodeSame(403);
        self::assertSame($requestId, $client->getResponse()->headers->get('X-Request-Id'));
        $records = [...$records, ...$this->records()];
        $this->disabled($client, $server);
        $disabled = $this->records();

        $failed = $this->only($records, 'login failed');
        self::assertSame('security', $failed['channel']);
        self::assertSame('warning', $failed['level']);
        $context = (array) $failed['context'];
        self::assertSame('invalid_credentials', $context['reason']);
        self::assertIsString($context['account_ref']);
        self::assertIsString($context['client_ref']);
        self::assertMatchesRegularExpression('/^[0-9a-f]{16}$/', $context['account_ref']);
        self::assertMatchesRegularExpression('/^[0-9a-f]{16}$/', $context['client_ref']);
        self::assertSame($user->id->toRfc4122(), ((array) $this->only($records, 'login succeeded')['context'])['user_id']);
        $rejected = $this->only($records, 'unsafe request rejected');
        self::assertSame('origin_mismatch', ((array) $rejected['context'])['reason']);
        self::assertSame($requestId, $rejected['request_id'], 'the log record and the answer share the request ID');

        self::assertSame('disabled', ((array) $this->only($disabled, 'login failed')['context'])['reason'], 'the log knows why; the answer does not');

        $all = json_encode([...$records, ...$disabled], \JSON_THROW_ON_ERROR);
        foreach ([$user->email, strtolower($user->email), $user->password, 'a wrong password', '203.0.113.77'] as $secret) {
            self::assertStringNotContainsString($secret, $all);
        }
    }

    /** @param array<string, string> $server */
    private function disabled(KernelBrowser $client, array $server): void
    {
        $user = Fixtures::from(self::getContainer())->user('disabled-logged');
        $connection = self::getContainer()->get('doctrine.dbal.default_connection');
        \assert($connection instanceof Connection);
        $connection->executeStatement('UPDATE users SET disabled_at = now() WHERE id = ?', [$user->id->toRfc4122()]);
        $client->request('POST', '/api/v1/auth/login', server: $server, content: json_encode(['email' => $user->email, 'password' => $user->password], \JSON_THROW_ON_ERROR));
        self::assertResponseStatusCodeSame(401);
    }

    /** @return list<array<mixed>> */
    private function records(): array
    {
        $handler = self::getContainer()->get('monolog.handler.main');
        self::assertInstanceOf(TestHandler::class, $handler);

        $records = [];
        foreach ($handler->getRecords() as $record) {
            self::assertIsString($record->formatted);
            $decoded = json_decode($record->formatted, true, flags: \JSON_THROW_ON_ERROR);
            self::assertIsArray($decoded);
            $records[] = $decoded;
        }

        return $records;
    }

    /**
     * @param list<array<mixed>> $records
     *
     * @return array<mixed>
     */
    private function only(array $records, string $message): array
    {
        $matches = array_values(array_filter($records, static fn (array $r): bool => \is_string($r['message']) && str_starts_with($r['message'], $message)));
        self::assertCount(1, $matches, $message);

        return $matches[0];
    }
}
