<?php

declare(strict_types=1);

namespace App\Tests\Integration\Security;

use App\Tests\Support\Http\ApiClient;
use App\Tests\Support\Http\FpmApiTestCase;
use App\Tests\Support\Security\Fixtures;
use App\Tests\Support\Session\FpmServer;

/**
 * Login, logout, session lifetime and invalidation over the real PHP-FPM,
 * PdoSessionHandler and PostgreSQL (ADR-019).
 */
final class AuthenticationTest extends FpmApiTestCase
{
    private const SESSION_ID = '/^[0-9a-f]{32}$/';

    public function testLoginAnswersWithTheSessionAndASafeCookie(): void
    {
        $user = $this->fixtures->user('ada');
        $organization = $this->fixtures->organization('northwind');
        $this->fixtures->member($organization, $user, 'REP');
        $client = $this->client();

        $response = $client->login($user->email, $user->password);

        $body = $response->json();
        self::assertTrue($body['authenticated']);
        self::assertSame(['id' => $user->id->toRfc4122(), 'email' => $user->email, 'displayName' => $user->displayName], $body['user']);
        self::assertIsArray($body['memberships']);
        self::assertCount(1, $body['memberships']);
        self::assertIsArray($body['memberships'][0]);
        self::assertSame($organization->toRfc4122(), $body['memberships'][0]['organizationId']);
        self::assertSame('REP', $body['memberships'][0]['role']);
        self::assertSame(['organization.view', 'membership.list'], $body['memberships'][0]['permissions']);
        self::assertNotSame('', $response->string('csrfToken'));
        $expiresAt = new \DateTimeImmutable($response->string('expiresAt'));
        self::assertEqualsWithDelta(time() + 8 * 3600, $expiresAt->getTimestamp(), 30, 'absolute lifetime of 8 hours');

        $cookies = $response->raw->setCookies(ApiClient::COOKIE);
        self::assertCount(1, $cookies);
        self::assertMatchesRegularExpression(self::SESSION_ID, (string) $client->sessionId());
        self::assertStringContainsStringIgnoringCase('; httponly', $cookies[0]);
        self::assertStringContainsStringIgnoringCase('; samesite=lax', $cookies[0]);
        self::assertStringContainsStringIgnoringCase('; path=/', $cookies[0]);
        self::assertStringNotContainsStringIgnoringCase('domain=', $cookies[0]);
        self::assertStringNotContainsStringIgnoringCase('secure', $cookies[0], 'plain HTTP: no Secure flag (FCRM-003 C-07)');
        self::assertStringContainsString('no-store', (string) $response->header('Cache-Control'));
        self::assertNotNull($this->sessionData($client->sessionId()), 'the session is stored in PostgreSQL');

        self::assertSame(200, $client->get('/api/v1/me')->status());
    }

    /** Session fixation: neither an existing session ID nor an attacker-chosen one survives a login. */
    public function testLoginAlwaysIssuesANewSessionId(): void
    {
        $user = $this->fixtures->user('grace');
        $client = $this->client();
        self::assertSame(200, $client->post('/api/_test/session/increment')->status());
        $before = (string) $client->sessionId();
        self::assertMatchesRegularExpression(self::SESSION_ID, $before);

        $client->login($user->email, $user->password);

        $after = (string) $client->sessionId();
        self::assertNotSame($before, $after);
        self::assertNull($this->sessionData($before), 'the previous session row is deleted');
        $old = $this->client();
        $old->useSessionId($before);
        self::assertSame(['authenticated' => false], $old->get('/api/v1/auth/session')->json());
        self::assertSame(401, $old->get('/api/v1/me')->status());

        $planted = str_repeat('a', 32);
        $victim = $this->client();
        $victim->useSessionId($planted);
        $victim->login($user->email, $user->password);
        self::assertNotSame($planted, $victim->sessionId());
        self::assertNull($this->sessionData($planted));
    }

    public function testFailedLoginsAreIndistinguishable(): void
    {
        $user = $this->fixtures->user('alan');
        $disabled = $this->fixtures->user('disabled');
        $this->fixtures->connection()->executeStatement('UPDATE users SET disabled_at = now() WHERE id = ?', [$disabled->id->toRfc4122()]);
        $sessions = $this->sessionCount();

        $answers = [];
        foreach ([
            'wrong password' => [$user->email, 'not the password at all'],
            'unknown e-mail' => ['nobody-'.bin2hex(random_bytes(4)).'@example.test', Fixtures::PASSWORD],
            'disabled account, right password' => [$disabled->email, $disabled->password],
            'empty password' => [$user->email, ''],
        ] as $case => [$email, $password]) {
            $response = $this->client()->post('/api/v1/auth/login', ['email' => $email, 'password' => $password]);
            self::assertSame(401, $response->status(), $case);
            self::assertSame('/problems/invalid-credentials', $response->problem(), $case);
            self::assertSame('Session realm="flowcrm"', $response->header('WWW-Authenticate'), $case);
            self::assertSame([], $response->raw->setCookies(ApiClient::COOKIE), "$case: no session cookie");
            $answers[$case] = $response->comparable();
        }

        self::assertCount(1, array_unique(array_map(static fn (array $a): string => serialize($a), $answers)), 'one answer for every failure');
        self::assertSame($sessions, $this->sessionCount(), 'a failed login stores no session');
    }

    public function testTheEmailAddressIsCaseInsensitive(): void
    {
        $user = $this->fixtures->user('hopper');

        $response = $this->client()->login(strtoupper($user->email), $user->password);

        self::assertSame($user->id->toRfc4122(), $response->value('user', 'id'));
    }

    public function testAnonymousSessionIntrospectionStartsNoSession(): void
    {
        $sessions = $this->sessionCount();
        $client = $this->client();

        $response = $client->get('/api/v1/auth/session');

        self::assertSame(200, $response->status());
        self::assertSame(['authenticated' => false], $response->json());
        self::assertSame([], $response->raw->header('Set-Cookie'));
        self::assertSame($sessions, $this->sessionCount());

        $me = $client->get('/api/v1/me');
        self::assertSame(401, $me->status());
        self::assertSame('/problems/unauthenticated', $me->problem());
        self::assertSame(['type', 'title', 'status', 'instance', 'requestId'], array_keys($me->json()), 'no data in a 401');
    }

    /** FCRM-002 AC-27: a replayed cookie after logout is a 401. */
    public function testLogoutEndsTheSessionOnTheServer(): void
    {
        $user = $this->fixtures->user('logout');
        $client = $this->client();
        $client->login($user->email, $user->password);
        $id = (string) $client->sessionId();

        $response = $client->post('/api/v1/auth/logout');

        self::assertSame(204, $response->status());
        self::assertNull($this->sessionData($id), 'the session row is deleted');
        self::assertNull($client->sessionId(), 'the cookie is expired');
        $replay = $this->client();
        $replay->useSessionId($id);
        self::assertSame(401, $replay->get('/api/v1/me')->status());
        self::assertSame(['authenticated' => false], $replay->get('/api/v1/auth/session')->json());

        self::assertSame(204, $this->client()->post('/api/v1/auth/logout')->status(), 'logout without a session is a no-op');
        self::assertSame(405, $this->client()->get('/api/v1/auth/logout')->status(), 'no logout by GET');
    }

    public function testLogoutNeedsTheCsrfTokenOfItsSession(): void
    {
        $user = $this->fixtures->user('csrf-logout');
        $client = $this->client();
        $client->login($user->email, $user->password);
        $other = $this->client();
        $other->login($user->email, $user->password);

        foreach (['no token' => null, 'token of another session' => $other->csrfToken(), 'forged token' => 'forged'] as $case => $token) {
            $client->useCsrfToken($token);
            $response = $client->post('/api/v1/auth/logout');
            self::assertSame(403, $response->status(), $case);
            self::assertSame('/problems/csrf-invalid', $response->problem(), $case);
            self::assertSame(200, $client->get('/api/v1/me')->status(), "$case: still logged in");
        }
    }

    public function testTheAbsoluteLifetimeEndsTheSession(): void
    {
        $server = new FpmServer(['FLOWCRM_SESSION_ABSOLUTE_LIFETIME' => '2']);
        $server->start();
        try {
            $user = $this->fixtures->user('absolute');
            $client = $this->client(server: $server);
            $login = $client->login($user->email, $user->password);
            self::assertEqualsWithDelta(time() + 2, new \DateTimeImmutable($login->string('expiresAt'))->getTimestamp(), 2);
            $id = (string) $client->sessionId();
            self::assertSame(200, $client->get('/api/v1/me')->status(), 'active use does not extend it');

            sleep(3);

            self::assertSame(401, $client->get('/api/v1/me')->status());
            self::assertNull($this->sessionData($id), 'the whole session ends, not only the login');
        } finally {
            $server->remove();
        }
    }

    public function testAnIdleSessionExpires(): void
    {
        $user = $this->fixtures->user('idle');
        $client = $this->client();
        $client->login($user->email, $user->password);
        $stored = $this->fixtures->connection()->fetchOne('SELECT sess_lifetime - extract(epoch FROM now())::int FROM sessions WHERE sess_id = ?', [$client->sessionId()]);
        self::assertEqualsWithDelta(1800, self::int($stored), 30, 'idle timeout of 30 minutes');

        $this->fixtures->connection()->executeStatement('UPDATE sessions SET sess_lifetime = ? WHERE sess_id = ?', [time() - 1, $client->sessionId()]);

        self::assertSame(401, $client->get('/api/v1/me')->status());
    }

    public function testDisablingAUserEndsTheirSessionsAndLogins(): void
    {
        $user = $this->fixtures->user('ended');
        $client = $this->client();
        $client->login($user->email, $user->password);
        $id = (string) $client->sessionId();

        self::assertSame(0, $this->console('flowcrm:user:disable', ['email' => $user->email])->getStatusCode());

        self::assertSame(401, $client->get('/api/v1/me')->status());
        self::assertNull($this->sessionData($id), 'the session is invalidated');
        self::assertSame(401, $this->client()->post('/api/v1/auth/login', ['email' => $user->email, 'password' => $user->password])->status());

        self::assertSame(0, $this->console('flowcrm:user:enable', ['email' => $user->email])->getStatusCode());
        $this->client()->login($user->email, $user->password);
    }

    public function testAnOperatorPasswordResetEndsEverySession(): void
    {
        $user = $this->fixtures->user('reset');
        $client = $this->client();
        $client->login($user->email, $user->password);

        $command = $this->console('flowcrm:user:reset-password', ['email' => $user->email], 'a brand new passphrase');
        self::assertSame(0, $command->getStatusCode(), $command->getDisplay());
        self::assertStringNotContainsString('a brand new passphrase', $command->getDisplay());

        self::assertSame(401, $client->get('/api/v1/me')->status());
        self::assertSame(401, $this->client()->post('/api/v1/auth/login', ['email' => $user->email, 'password' => $user->password])->status());
        $this->client()->login($user->email, 'a brand new passphrase');
    }

    public function testChangingTheOwnPasswordKeepsThisSessionAndEndsTheOthers(): void
    {
        $user = $this->fixtures->user('changer');
        $client = $this->client();
        $client->login($user->email, $user->password);
        $other = $this->client();
        $other->login($user->email, $user->password);
        $before = (string) $client->sessionId();

        $response = $client->post('/api/v1/me/password', ['currentPassword' => $user->password, 'newPassword' => 'an even better passphrase']);

        self::assertSame(204, $response->status(), $response->raw->body);
        self::assertNotSame($before, $client->sessionId(), 'the session gets a new ID');
        self::assertNull($this->sessionData($before));
        self::assertSame(200, $client->get('/api/v1/me')->status(), 'this session stays logged in');
        self::assertSame(401, $other->get('/api/v1/me')->status(), 'every other session ends');
        $this->client()->login($user->email, 'an even better passphrase');
    }

    public function testThePasswordChangeValidatesAndLimitsWrongCurrentPasswords(): void
    {
        $user = $this->fixtures->user('limited');
        $client = $this->client();
        $client->login($user->email, $user->password);

        $short = $client->post('/api/v1/me/password', ['currentPassword' => $user->password, 'newPassword' => 'too short']);
        self::assertSame(422, $short->status());
        self::assertSame([['pointer' => '/newPassword', 'code' => 'PASSWORD_TOO_SHORT']], $short->json()['errors']);
        $long = $client->post('/api/v1/me/password', ['currentPassword' => $user->password, 'newPassword' => str_repeat('ż', 129)]);
        self::assertSame([['pointer' => '/newPassword', 'code' => 'PASSWORD_TOO_LONG']], $long->json()['errors']);
        $unknown = $client->post('/api/v1/me/password', ['currentPassword' => $user->password, 'newPassword' => 'long enough password', 'userId' => 'x']);
        self::assertSame([['pointer' => '/userId', 'code' => 'UNKNOWN_FIELD']], $unknown->json()['errors']);

        for ($i = 1; $i <= 5; ++$i) {
            $wrong = $client->post('/api/v1/me/password', ['currentPassword' => 'wrong current '.$i, 'newPassword' => 'long enough password']);
            self::assertSame(422, $wrong->status());
            self::assertSame([['pointer' => '/currentPassword', 'code' => 'INVALID_CURRENT_PASSWORD']], $wrong->json()['errors']);
        }
        $limited = $client->post('/api/v1/me/password', ['currentPassword' => $user->password, 'newPassword' => 'long enough password']);
        self::assertSame(429, $limited->status());
        self::assertSame('/problems/too-many-requests', $limited->problem());
        self::assertGreaterThan(0, (int) $limited->header('Retry-After'));
        $this->client()->login($user->email, $user->password);
    }

    /** No password hash, e-mail address or organization in the stored session (ADR-019). */
    public function testTheSessionStoresNoCredentialsAndNoTenant(): void
    {
        $user = $this->fixtures->user('stored');
        $organization = $this->fixtures->organization('stored');
        $this->fixtures->member($organization, $user, 'ADMIN');
        $client = $this->client();
        $client->login($user->email, $user->password);
        self::assertSame(200, $client->get('/api/v1/organizations/'.$organization->toRfc4122())->status());

        $data = (string) $this->sessionData($client->sessionId());
        $hash = self::string($this->fixtures->connection()->fetchOne('SELECT password_hash FROM users WHERE id = ?', [$user->id->toRfc4122()]));

        self::assertStringContainsString($user->id->toRfc4122(), $data, 'the session belongs to the user');
        self::assertStringNotContainsString($hash, $data);
        self::assertStringNotContainsString('$argon2', $data);
        self::assertStringNotContainsString($user->password, $data);
        self::assertStringNotContainsString($user->email, $data);
        self::assertStringNotContainsString($organization->toRfc4122(), $data);
    }

    /** A hash made with other parameters is replaced at login; the session stays valid. */
    public function testAnOutdatedHashIsUpgradedAtLogin(): void
    {
        $user = $this->fixtures->user('legacy', hash: password_hash(Fixtures::PASSWORD, \PASSWORD_BCRYPT, ['cost' => 4]));
        $client = $this->client();

        $client->login($user->email, $user->password);

        $hash = self::string($this->fixtures->connection()->fetchOne('SELECT password_hash FROM users WHERE id = ?', [$user->id->toRfc4122()]));
        self::assertStringStartsWith('$argon2id$', $hash);
        self::assertSame(200, $client->get('/api/v1/me')->status(), 'the upgrading session stays logged in');
        $this->client()->login($user->email, $user->password);
    }

    public function testTheCsrfTokenRotatesWithEveryLogin(): void
    {
        $user = $this->fixtures->user('rotation');
        $client = $this->client();
        $first = $client->login($user->email, $user->password)->string('csrfToken');

        $second = $client->login($user->email, $user->password)->string('csrfToken');

        $client->useCsrfToken($first);
        self::assertSame(403, $client->post('/api/v1/auth/logout')->status(), 'the token from before the login is no longer valid');
        $client->useCsrfToken($second);
        self::assertSame(204, $client->post('/api/v1/auth/logout')->status());
    }

    private function sessionCount(): int
    {
        return self::int($this->fixtures->connection()->fetchOne('SELECT count(*) FROM sessions'));
    }
}
