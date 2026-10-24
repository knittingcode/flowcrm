<?php

declare(strict_types=1);

namespace App\Tests\Integration\Security;

use App\Tests\Support\Http\ApiClient;
use App\Tests\Support\Http\ApiResponse;
use App\Tests\Support\Http\FpmApiTestCase;
use Symfony\Component\EventDispatcher\EventDispatcherInterface;
use Symfony\Component\Security\Http\Event\CheckPassportEvent;
use Symfony\Component\Security\Http\EventListener\CheckCredentialsListener;
use Symfony\Component\Security\Http\EventListener\LoginThrottlingListener;

/**
 * Layered login throttling (ADR-019) over the real PHP-FPM, with the state
 * in PostgreSQL: 5 failures per account and client IP per 15 minutes, 50 per
 * client IP, 100 per account and day. The harness plays the edge and gives
 * each client its own address (X-Forwarded-For from the trusted harness,
 * compose.test.yaml); in dev and prod the edge passes the client's address
 * as REMOTE_ADDR and no proxy is trusted. Spoofing through the real edge is
 * covered by tests/app/stack.sh ST-72 and tests/app/prodlike.sh PL-22.
 */
final class LoginThrottlingTest extends FpmApiTestCase
{
    public function testTheSixthFailureOfAnAccountFromOneClientIsRefusedEvenWithTheRightPassword(): void
    {
        $user = $this->fixtures->user('throttled');
        $client = $this->client();

        for ($i = 1; $i <= 5; ++$i) {
            self::assertSame(401, $this->tryLogin($client, $user->email, 'wrong password '.$i)->status(), "failure $i");
        }
        $limited = $this->tryLogin($client, $user->email, $user->password);

        self::assertSame(429, $limited->status(), 'checked before the password');
        self::assertSame('/problems/too-many-requests', $limited->problem());
        self::assertGreaterThanOrEqual(60, (int) $limited->header('Retry-After'));
        self::assertNull($client->sessionId());
        self::assertSame(200, $this->tryLogin($this->client(), $user->email, $user->password)->status(), 'another client is not affected');
    }

    /** An unknown account is limited exactly like a known one: the 429 reveals nothing. */
    public function testUnknownAccountsAreLimitedTheSameWay(): void
    {
        $known = $this->fixtures->user('known');
        $unknown = 'unknown-'.bin2hex(random_bytes(4)).'@example.test';
        $answers = [];
        foreach ([$known->email, $unknown] as $email) {
            $client = $this->client();
            $statuses = [];
            for ($i = 1; $i <= 6; ++$i) {
                $statuses[] = $this->tryLogin($client, $email, 'wrong password '.$i)->status();
            }
            $answers[] = $statuses;
        }

        self::assertSame([401, 401, 401, 401, 401, 429], $answers[0]);
        self::assertSame($answers[0], $answers[1]);
    }

    public function testTheAccountLimitCountsCaseInsensitively(): void
    {
        $user = $this->fixtures->user('casing');
        $client = $this->client();
        foreach (['lower', 'UPPER', 'Mixed', 'lower', 'UPPER'] as $i => $case) {
            $email = match ($case) {
                'UPPER' => strtoupper($user->email),
                'Mixed' => ucfirst($user->email),
                default => $user->email,
            };
            self::assertSame(401, $this->tryLogin($client, $email, 'wrong '.$i)->status());
        }

        self::assertSame(429, $this->tryLogin($client, $user->email, $user->password)->status());
    }

    /**
     * Every spelling the lookup resolves to the same account shares its
     * windows. The lookup compares PostgreSQL lower() values; Unicode
     * variants such as U+0130 (lower() maps it to "i", full case mapping to
     * "i" + U+0307) or a final capital sigma must not open fresh windows.
     */
    public function testEveryVariantThatResolvesToTheAccountSharesItsWindow(): void
    {
        $user = $this->fixtures->user('casing');
        $variants = [
            $user->email,
            str_replace('i', "\u{130}", $user->email),
            strtoupper($user->email),
            str_replace('i', 'I', $user->email),
            strtoupper(str_replace('i', "\u{130}", $user->email)),
        ];
        self::assertSame(200, $this->tryLogin($this->client(), $variants[1], $user->password)->status(), 'the variant resolves to the account');
        $client = $this->client();
        foreach ($variants as $i => $email) {
            self::assertSame(401, $this->tryLogin($client, $email, 'wrong '.$i)->status(), "failure $i");
        }

        foreach ($variants as $i => $email) {
            self::assertSame(429, $this->tryLogin($client, $email, $user->password)->status(), "variant $i is limited");
        }
    }

    /** A success clears only the account-and-IP window, not the IP's. */
    public function testASuccessfulLoginClearsOnlyTheAccountAndIpWindow(): void
    {
        $user = $this->fixtures->user('reset');
        $client = $this->client();
        for ($i = 1; $i <= 4; ++$i) {
            $this->tryLogin($client, $user->email, 'wrong '.$i);
        }
        self::assertSame(200, $this->tryLogin($client, $user->email, $user->password)->status());
        for ($i = 1; $i <= 5; ++$i) {
            self::assertSame(401, $this->tryLogin($client, $user->email, 'again wrong '.$i)->status(), "after the reset, failure $i");
        }
        self::assertSame(429, $this->tryLogin($client, $user->email, $user->password)->status());
    }

    /**
     * Password spraying from one client: 50 failures over many accounts,
     * then even its own account's correct login is refused. Logging in to an
     * account of its own in between does not reset the IP window.
     */
    public function testOneClientIpIsLimitedAcrossAccounts(): void
    {
        $own = $this->fixtures->user('sprayer');
        $ip = $this->uniqueIp();
        for ($i = 1; $i <= 49; ++$i) {
            self::assertSame(401, $this->tryLogin($this->client($ip), 'victim-'.$i.'-'.bin2hex(random_bytes(3)).'@example.test', 'Winter2026!')->status(), "failure $i");
        }
        self::assertSame(200, $this->tryLogin($this->client($ip), $own->email, $own->password)->status(), 'a login of its own account');
        self::assertSame(401, $this->tryLogin($this->client($ip), 'victim-50@example.test', 'Winter2026!')->status());

        self::assertSame(429, $this->tryLogin($this->client($ip), $own->email, $own->password)->status(), 'the IP window was not reset');
        self::assertSame(401, $this->tryLogin($this->client($this->uniqueIp()), 'victim-51@example.test', 'Winter2026!')->status(), 'other clients are not affected');
    }

    /** A distributed attack on one account: 100 failures from 100 client IPs, then the account is limited. */
    public function testOneAccountIsLimitedAcrossClientIps(): void
    {
        $user = $this->fixtures->user('target');
        for ($i = 1; $i <= 100; ++$i) {
            self::assertSame(401, $this->tryLogin($this->client($this->uniqueIp()), $user->email, 'guess '.$i)->status(), "failure $i");
        }

        self::assertSame(429, $this->tryLogin($this->client($this->uniqueIp()), $user->email, $user->password)->status());
    }

    /** The limit is keyed by the client IP the edge forwards, not by the edge's own address. */
    public function testTheForwardedClientIpIsTheKey(): void
    {
        $user = $this->fixtures->user('forwarded');
        $first = $this->client($this->uniqueIp());
        for ($i = 1; $i <= 5; ++$i) {
            $this->tryLogin($first, $user->email, 'wrong '.$i);
        }
        self::assertSame(429, $this->tryLogin($first, $user->email, $user->password)->status());

        self::assertSame(200, $this->tryLogin($this->client($this->uniqueIp()), $user->email, $user->password)->status());
    }

    /** The throttle runs on the passport before the credentials are checked (no hashing when limited). */
    public function testTheLimitIsCheckedBeforeThePassword(): void
    {
        $dispatcher = self::getContainer()->get('security.event_dispatcher.api');
        \assert($dispatcher instanceof EventDispatcherInterface);
        $priorities = [];
        foreach ($dispatcher->getListeners(CheckPassportEvent::class) as $listener) {
            if (\is_array($listener) && \is_object($listener[0]) && \is_callable($listener)) {
                $priorities[$listener[0]::class] = $dispatcher->getListenerPriority(CheckPassportEvent::class, $listener);
            }
        }

        self::assertArrayHasKey(LoginThrottlingListener::class, $priorities);
        self::assertArrayHasKey(CheckCredentialsListener::class, $priorities);
        self::assertGreaterThan($priorities[CheckCredentialsListener::class], $priorities[LoginThrottlingListener::class]);
    }

    private function tryLogin(ApiClient $client, string $email, string $password): ApiResponse
    {
        return $client->post('/api/v1/auth/login', ['email' => $email, 'password' => $password]);
    }

    private function uniqueIp(): string
    {
        return \sprintf('2001:db8:%x:%x::%x', random_int(0, 0xFFFF), random_int(0, 0xFFFF), random_int(1, 0xFFFF));
    }
}
