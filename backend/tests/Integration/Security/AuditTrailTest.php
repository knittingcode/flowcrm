<?php

declare(strict_types=1);

namespace App\Tests\Integration\Security;

use App\Tests\Support\Http\FpmApiTestCase;
use Symfony\Component\Uid\Uuid;

/**
 * Successful security-relevant actions are in the append-only audit log,
 * with their actor and request ID and without secrets or an IP address;
 * failures are not, so anonymous traffic cannot fill it (ADR-019).
 */
final class AuditTrailTest extends FpmApiTestCase
{
    public function testLoginPasswordChangeAndLogoutAreAudited(): void
    {
        $user = $this->fixtures->user('audited');
        $client = $this->client();
        $login = $client->login($user->email, $user->password);
        $client->post('/api/v1/me/password', ['currentPassword' => $user->password, 'newPassword' => 'a new audited passphrase']);
        $sessionId = (string) $client->sessionId();
        $logout = $client->post('/api/v1/auth/logout');

        $events = $this->events($user->id);
        self::assertSame(['auth.login_succeeded', 'auth.password_changed', 'auth.logout'], array_column($events, 'action'));
        foreach ($events as $event) {
            self::assertSame('user', $event['actor_type']);
            self::assertSame($user->id->toRfc4122(), $event['actor_user_id']);
            self::assertNull($event['actor_role']);
            self::assertNull($event['organization_id'], 'global events belong to no organization (BR-33)');
            self::assertNull($event['ip'], 'no raw IP address in the immutable log');
            self::assertSame('[]', $event['changes'], 'nothing beyond the action');
            self::assertIsString($event['request_id']);
            self::assertTrue(Uuid::isValid($event['request_id']));
        }
        self::assertSame($login->header('X-Request-Id'), $events[0]['request_id']);
        self::assertSame($logout->header('X-Request-Id'), $events[2]['request_id']);

        $all = json_encode($events, \JSON_THROW_ON_ERROR);
        foreach ([$user->password, 'a new audited passphrase', $user->email, $sessionId, $login->string('csrfToken'), '$argon2'] as $secret) {
            self::assertStringNotContainsString($secret, $all);
        }
    }

    public function testFailedLoginsWriteNoAuditEvents(): void
    {
        $user = $this->fixtures->user('not-audited');
        $before = $this->auditEventCount();

        for ($i = 1; $i <= 6; ++$i) {
            $this->client()->post('/api/v1/auth/login', ['email' => $user->email, 'password' => 'wrong '.$i]);
            $this->client()->post('/api/v1/auth/login', ['email' => 'unknown-'.$i.'-'.bin2hex(random_bytes(3)).'@example.test', 'password' => 'wrong']);
        }

        self::assertSame($before, $this->auditEventCount());
    }

    public function testOperatorProvisioningIsAuditedWithTheOperatorAsActor(): void
    {
        $email = 'provisioned-'.bin2hex(random_bytes(4)).'@example.test';
        self::assertSame(0, $this->console('flowcrm:user:create', ['--email' => $email, '--display-name' => 'Provisioned'], 'a provisioned passphrase')->getStatusCode());
        $create = $this->console('flowcrm:organization:create', ['--name' => 'Provisioned Ltd', '--admin-email' => $email]);
        self::assertSame(0, $create->getStatusCode(), $create->getDisplay());
        $organization = trim($create->getDisplay());

        $rows = $this->fixtures->connection()->fetchAllAssociative(
            "SELECT action, actor_type, actor_user_id, organization_id, changes::text AS changes, ip FROM audit_events WHERE organization_id = ? OR (entity_type = 'user' AND entity_id = (SELECT id FROM users WHERE email = ?)) ORDER BY occurred_at, id",
            [$organization, $email],
        );
        self::assertSame(['user.created', 'organization.created', 'membership.added'], array_column($rows, 'action'));
        foreach ($rows as $row) {
            self::assertSame('platform_operator', $row['actor_type']);
            self::assertNull($row['actor_user_id']);
            self::assertNull($row['ip']);
        }
        self::assertSame('{"role": "ADMIN"}', $rows[2]['changes']);
        self::assertStringNotContainsString('a provisioned passphrase', json_encode($rows, \JSON_THROW_ON_ERROR));
    }

    /** @return list<array<string, mixed>> */
    private function events(Uuid $user): array
    {
        return $this->fixtures->connection()->fetchAllAssociative(
            "SELECT action, actor_type, actor_user_id, actor_role, organization_id, changes::text AS changes, request_id, ip FROM audit_events WHERE entity_type = 'user' AND entity_id = ? ORDER BY occurred_at, id",
            [$user->toRfc4122()],
        );
    }

    private function auditEventCount(): int
    {
        return self::int($this->fixtures->connection()->fetchOne('SELECT count(*) FROM audit_events'));
    }
}
