<?php

declare(strict_types=1);

namespace App\Tests\Integration\Security;

use App\Tests\Support\Security\Fixtures;
use Monolog\Handler\TestHandler;
use Symfony\Bundle\FrameworkBundle\Test\WebTestCase;

/**
 * Refused membership changes are not audited but logged on the security
 * channel (ADR-020 decision 4, FCRM-002 NFR-012): a structured record with
 * the reason, the actor, the organization, the route and the request ID,
 * never the e-mail address that was looked up.
 */
final class MembershipRefusalLoggingTest extends WebTestCase
{
    public function testRefusedLookupsAreLoggedWithoutTheAddress(): void
    {
        $client = self::createClient();
        $client->disableReboot();
        $fixtures = Fixtures::from(self::getContainer());
        $organization = $fixtures->organization('logged');
        $admin = $fixtures->user('logging-admin');
        $fixtures->member($organization, $admin, 'ADMIN');
        $member = $fixtures->user('logged-member');
        $fixtures->member($organization, $member, 'REP');
        $unknown = 'Nobody-'.bin2hex(random_bytes(4)).'@Example.test';
        $server = ['CONTENT_TYPE' => 'application/json', 'HTTP_ORIGIN' => 'http://localhost'];

        $client->request('POST', '/api/v1/auth/login', server: $server, content: json_encode(['email' => $admin->email, 'password' => $admin->password], \JSON_THROW_ON_ERROR));
        self::assertResponseStatusCodeSame(200);
        $session = json_decode((string) $client->getResponse()->getContent(), true, flags: \JSON_THROW_ON_ERROR);
        self::assertIsArray($session);
        $token = $session['csrfToken'] ?? null;
        self::assertIsString($token);
        $this->records();

        $refusals = [];
        foreach (['unknown_user' => [$unknown, 422], 'membership_exists' => [strtoupper($member->email), 409]] as $reason => [$email, $status]) {
            $client->request('POST', '/api/v1/organizations/'.$organization->toRfc4122().'/members', server: $server + ['HTTP_X_CSRF_TOKEN' => $token], content: json_encode(['email' => $email, 'role' => 'REP'], \JSON_THROW_ON_ERROR));
            self::assertResponseStatusCodeSame($status);
            $records = $this->records();
            $refusals[$reason] = [$this->only($records, 'membership change refused'), $client->getResponse()->headers->get('X-Request-Id'), $records];
        }

        foreach ($refusals as $reason => [$record, $requestId, $records]) {
            self::assertNotNull($requestId);
            self::assertSame('security', $record['channel'], $reason);
            self::assertSame('notice', $record['level'], $reason);
            self::assertSame('membership change refused: '.$reason, $record['message']);
            self::assertSame([
                'event' => 'membership_change_refused',
                'reason' => $reason,
                'user_id' => $admin->id->toRfc4122(),
                'organization_id' => $organization->toRfc4122(),
                'route' => 'api_v1_organization_member_add',
            ], $record['context'], $reason);
            self::assertSame($requestId, $record['request_id'], $reason);
            $all = strtolower(json_encode($records, \JSON_THROW_ON_ERROR));
            foreach ([$unknown, $member->email] as $address) {
                self::assertStringNotContainsString(strtolower($address), $all, $reason.': no e-mail address in any record');
            }
        }
    }

    /** @return list<array<mixed>> the formatted records since the last call */
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
        $handler->clear();

        return $records;
    }

    /**
     * @param list<array<mixed>> $records
     *
     * @return array<mixed>
     */
    private function only(array $records, string $message): array
    {
        $matches = array_values(array_filter($records, static fn (array $r): bool => \is_string($r['message'] ?? null) && str_starts_with($r['message'], $message)));
        self::assertCount(1, $matches, $message);

        return $matches[0];
    }
}
