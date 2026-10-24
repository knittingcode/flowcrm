<?php

declare(strict_types=1);

namespace App\Tests\Integration\Security;

use App\Tests\Support\Database\TestDatabase;
use App\Tests\Support\Http\FpmApiTestCase;
use App\Tests\Support\Security\Fixtures;
use App\Tests\Support\Security\TestUser;
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

    /** The operator's user changes are audited by action, with the operator as actor and nothing beyond the action. */
    public function testOperatorUserChangesAreAuditedWithTheirAction(): void
    {
        $user = $this->fixtures->user('operator-changes');

        self::assertSame(0, $this->console('flowcrm:user:disable', ['email' => $user->email])->getStatusCode());
        self::assertSame(0, $this->console('flowcrm:user:enable', ['email' => $user->email])->getStatusCode());
        self::assertSame(0, $this->console('flowcrm:user:reset-password', ['email' => $user->email], 'an operator reset passphrase')->getStatusCode());

        $events = $this->events($user->id);
        self::assertSame(['user.disabled', 'user.enabled', 'user.password_reset'], array_column($events, 'action'));
        foreach ($events as $event) {
            self::assertSame('platform_operator', $event['actor_type']);
            self::assertNull($event['actor_user_id']);
            self::assertNull($event['actor_role']);
            self::assertNull($event['organization_id'], 'global events belong to no organization (BR-33)');
            self::assertNull($event['ip']);
            self::assertSame('[]', $event['changes'], 'nothing beyond the action');
        }
        $all = json_encode($events, \JSON_THROW_ON_ERROR);
        foreach (['an operator reset passphrase', $user->email, '$argon2'] as $secret) {
            self::assertStringNotContainsString($secret, $all);
        }
    }

    /** Without its audit event there is no login: no session, no cookie that authenticates. */
    public function testALoginWhoseAuditEventCannotBeWrittenFails(): void
    {
        $user = $this->fixtures->user('audit-down-login');
        $sessions = $this->sessionCount();
        $client = $this->client();

        $response = $this->whileAuditFailsFor($user, static fn () => $client->post('/api/v1/auth/login', ['email' => $user->email, 'password' => $user->password]));

        self::assertSame(500, $response->status());
        self::assertSame($response->header('X-Request-Id'), $response->value('requestId'));
        self::assertArrayNotHasKey('csrfToken', $response->json());
        self::assertSame(401, $client->get('/api/v1/me')->status(), 'whatever cookie the client kept does not authenticate');
        self::assertSame($sessions, $this->sessionCount(), 'no session is stored');
        self::assertSame([], $this->events($user->id));
        $this->client()->login($user->email, $user->password);
    }

    /** A logout ends the session even when its audit event cannot be written. */
    public function testALogoutEndsTheSessionEvenWhenItsAuditEventCannotBeWritten(): void
    {
        $user = $this->fixtures->user('audit-down-logout');
        $client = $this->client();
        $client->login($user->email, $user->password);
        $id = (string) $client->sessionId();

        $response = $this->whileAuditFailsFor($user, static fn () => $client->post('/api/v1/auth/logout'));

        self::assertSame(500, $response->status());
        self::assertNull($this->sessionData($id), 'the session row is deleted');
        $replay = $this->client();
        $replay->useSessionId($id);
        self::assertSame(401, $replay->get('/api/v1/me')->status());
        self::assertSame(['auth.login_succeeded'], array_column($this->events($user->id), 'action'));
    }

    /** The password and its audit event are one transaction: without the event nothing changes. */
    public function testAPasswordChangeWhoseAuditEventCannotBeWrittenChangesNothing(): void
    {
        $user = $this->fixtures->user('audit-down-password');
        $client = $this->client();
        $client->login($user->email, $user->password);
        $other = $this->client();
        $other->login($user->email, $user->password);
        $id = (string) $client->sessionId();

        $response = $this->whileAuditFailsFor($user, static fn () => $client->post('/api/v1/me/password', ['currentPassword' => $user->password, 'newPassword' => 'a never stored passphrase']));

        self::assertSame(500, $response->status());
        self::assertSame($id, $client->sessionId(), 'the session keeps its ID');
        self::assertSame(200, $client->get('/api/v1/me')->status());
        self::assertSame(200, $other->get('/api/v1/me')->status(), 'the other sessions continue: the credentials did not change');
        self::assertSame(401, $this->client()->post('/api/v1/auth/login', ['email' => $user->email, 'password' => 'a never stored passphrase'])->status());
        $this->client()->login($user->email, $user->password);
        self::assertNotContains('auth.password_changed', array_column($this->events($user->id), 'action'));
    }

    /** Operator changes and their audit events are one transaction too. */
    public function testOperatorChangesWhoseAuditEventCannotBeWrittenChangeNothing(): void
    {
        $user = $this->fixtures->user('audit-down-operator');
        $client = $this->client();
        $client->login($user->email, $user->password);

        $this->whileAuditFailsFor($user, function () use ($user): void {
            self::assertNotSame(0, $this->safeConsole('flowcrm:user:disable', ['email' => $user->email]));
            self::assertNotSame(0, $this->safeConsole('flowcrm:user:reset-password', ['email' => $user->email], 'a never stored passphrase'));
        });

        self::assertNull($this->fixtures->connection()->fetchOne('SELECT disabled_at FROM users WHERE id = ?', [$user->id->toRfc4122()]));
        self::assertSame(200, $client->get('/api/v1/me')->status(), 'neither disabled nor a new password');
        self::assertSame(['auth.login_succeeded'], array_column($this->events($user->id), 'action'));
    }

    /** Enabling and provisioning are one transaction with their audit events too: without them nothing is stored. */
    public function testOperatorEnableAndProvisioningWhoseAuditEventCannotBeWrittenChangeNothing(): void
    {
        $disabled = $this->fixtures->user('audit-down-enable');
        self::assertSame(0, $this->console('flowcrm:user:disable', ['email' => $disabled->email])->getStatusCode());
        $this->whileAuditFailsFor($disabled, function () use ($disabled): void {
            self::assertNotSame(0, $this->safeConsole('flowcrm:user:enable', ['email' => $disabled->email]));
        });
        self::assertNotNull($this->fixtures->connection()->fetchOne('SELECT disabled_at FROM users WHERE id = ?', [$disabled->id->toRfc4122()]), 'still disabled');
        self::assertSame(['user.disabled'], array_column($this->events($disabled->id), 'action'));

        $email = 'audit-down-create-'.bin2hex(random_bytes(4)).'@example.test';
        $this->whileAuditFails("NEW.action = 'user.created'", function () use ($email): void {
            self::assertNotSame(0, $this->safeConsole('flowcrm:user:create', ['--email' => $email, '--display-name' => 'Never Stored'], 'a never stored passphrase'));
        });
        self::assertFalse($this->fixtures->connection()->fetchOne('SELECT id FROM users WHERE email = ?', [$email]), 'no user without its event');

        $admin = $this->fixtures->user('audit-down-organization');
        $name = 'Never Stored '.bin2hex(random_bytes(4));
        $this->whileAuditFails("NEW.action = 'membership.added' AND NEW.actor_type = 'platform_operator'", function () use ($name, $admin): void {
            self::assertNotSame(0, $this->safeConsole('flowcrm:organization:create', ['--name' => $name, '--admin-email' => $admin->email]));
        });
        $connection = $this->fixtures->connection();
        self::assertFalse($connection->fetchOne('SELECT id FROM organizations WHERE name = ?', [$name]), 'no organization without the event of its first membership');
        self::assertSame(0, self::int($connection->fetchOne('SELECT count(*) FROM memberships WHERE user_id = ?', [$admin->id->toRfc4122()])));

        $organization = $this->fixtures->organization('audit-down-member');
        $member = $this->fixtures->user('audit-down-member');
        $this->whileAuditFails(\sprintf("NEW.organization_id = '%s'", $organization->toRfc4122()), function () use ($organization, $member): void {
            self::assertNotSame(0, $this->safeConsole('flowcrm:membership:add', ['--organization' => $organization->toRfc4122(), '--email' => $member->email, '--role' => 'REP']));
        });
        $connection = $this->fixtures->connection();
        self::assertSame(0, self::int($connection->fetchOne('SELECT count(*) FROM memberships WHERE organization_id = ?', [$organization->toRfc4122()])), 'no membership without its event');
        self::assertSame(0, self::int($connection->fetchOne('SELECT count(*) FROM audit_events WHERE organization_id = ?', [$organization->toRfc4122()])));
    }

    /**
     * Runs $action while every audit event about $user fails to be written
     * (a trigger of the schema owner, removed afterwards).
     *
     * @template T
     *
     * @param callable(): T $action
     *
     * @return T
     */
    private function whileAuditFailsFor(TestUser $user, callable $action): mixed
    {
        return $this->whileAuditFails(\sprintf("NEW.entity_id = '%s'", $user->id->toRfc4122()), $action);
    }

    /**
     * Runs $action while every audit event matching the trigger condition
     * $when (SQL over NEW, written by the test) fails to be written.
     *
     * @template T
     *
     * @param callable(): T $action
     *
     * @return T
     */
    private function whileAuditFails(string $when, callable $action): mixed
    {
        $owner = TestDatabase::owner();
        $owner->executeStatement("CREATE OR REPLACE FUNCTION test_audit_unavailable() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'audit storage unavailable (test)'; END $$");
        $owner->executeStatement(\sprintf('CREATE TRIGGER test_audit_unavailable BEFORE INSERT ON audit_events FOR EACH ROW WHEN (%s) EXECUTE FUNCTION test_audit_unavailable()', $when));
        try {
            return $action();
        } finally {
            $owner->executeStatement('DROP TRIGGER test_audit_unavailable ON audit_events');
            $owner->executeStatement('DROP FUNCTION test_audit_unavailable()');
            $owner->close();
        }
    }

    /**
     * An operator command whose failure is an exception or an exit code.
     *
     * @param array<string, string> $input
     */
    private function safeConsole(string $name, array $input, ?string $stdin = null): int
    {
        try {
            $status = $this->console($name, $input, $stdin)->getStatusCode();
        } catch (\Throwable) {
            $status = 1;
        }
        // The failed flush closed the kernel's entity manager.
        self::bootKernel();
        $this->fixtures = Fixtures::from(self::getContainer());

        return $status;
    }

    private function sessionCount(): int
    {
        return self::int($this->fixtures->connection()->fetchOne('SELECT count(*) FROM sessions'));
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
