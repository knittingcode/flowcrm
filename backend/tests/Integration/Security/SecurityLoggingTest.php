<?php

declare(strict_types=1);

namespace App\Tests\Integration\Security;

use App\Tests\Support\Security\Fixtures;
use Monolog\Handler\TestHandler;
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
        $client->request('POST', '/api/v1/auth/logout', server: ['CONTENT_TYPE' => 'application/json', 'HTTP_ORIGIN' => 'https://evil.example']);
        self::assertResponseStatusCodeSame(403);
        $records = [...$records, ...$this->records()];

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
        self::assertSame('origin_mismatch', ((array) $this->only($records, 'unsafe request rejected')['context'])['reason']);

        $all = json_encode($records, \JSON_THROW_ON_ERROR);
        foreach ([$user->email, strtolower($user->email), $user->password, 'a wrong password', '203.0.113.77'] as $secret) {
            self::assertStringNotContainsString($secret, $all);
        }
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
