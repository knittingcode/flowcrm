<?php

declare(strict_types=1);

namespace App\Tests\Unit\Identity;

use App\Identity\Infrastructure\Security\LoginRateLimiter;
use PHPUnit\Framework\TestCase;
use Symfony\Component\HttpFoundation\Request;
use Symfony\Component\RateLimiter\RateLimiterFactory;
use Symfony\Component\RateLimiter\Storage\InMemoryStorage;
use Symfony\Component\Security\Http\SecurityRequestAttributes;

final class LoginRateLimiterTest extends TestCase
{
    public function testTheStoredKeysContainNeitherTheAddressNorTheIp(): void
    {
        $storage = new InMemoryStorage();
        $limiter = $this->limiter($storage);

        $limiter->consume($this->request('Someone@Example.test', '203.0.113.9'));

        $keys = array_keys((array) new \ReflectionProperty(InMemoryStorage::class, 'buckets')->getValue($storage));
        self::assertCount(3, $keys);
        foreach ($keys as $key) {
            self::assertStringNotContainsStringIgnoringCase('someone', (string) $key);
            self::assertStringNotContainsString('203.0.113.9', (string) $key);
        }
    }

    public function testASuccessResetsOnlyTheAccountAndIpWindow(): void
    {
        $limiter = $this->limiter(new InMemoryStorage());
        $request = $this->request('a@example.test', '203.0.113.9');
        for ($i = 0; $i < 4; ++$i) {
            $limiter->consume($request);
        }

        $limiter->reset($request);

        self::assertSame(5, $limiter->peek($request)->getRemainingTokens(), 'the account-and-IP window is cleared');
        for ($i = 0; $i < 46; ++$i) {
            self::assertTrue($limiter->consume($this->request("other$i@example.test", '203.0.113.9'))->isAccepted(), "failure $i");
        }
        self::assertFalse($limiter->consume($this->request('next@example.test', '203.0.113.9'))->isAccepted(), 'the IP window kept the 4 failures from before the reset');
    }

    public function testTheAccountIsCaseInsensitive(): void
    {
        $limiter = $this->limiter(new InMemoryStorage());
        for ($i = 0; $i < 5; ++$i) {
            $limiter->consume($this->request($i % 2 ? 'A@EXAMPLE.TEST' : 'a@example.test', '203.0.113.9'));
        }

        self::assertFalse($limiter->consume($this->request('a@Example.Test', '203.0.113.9'))->isAccepted());
    }

    private function limiter(InMemoryStorage $storage): LoginRateLimiter
    {
        $factory = static fn (string $id, int $limit, string $interval): RateLimiterFactory => new RateLimiterFactory(['id' => $id, 'policy' => 'sliding_window', 'limit' => $limit, 'interval' => $interval], $storage);

        return new LoginRateLimiter($factory('account_ip', 5, '15 minutes'), $factory('ip', 50, '15 minutes'), $factory('account', 100, '1 day'), 'secret');
    }

    private function request(string $email, string $ip): Request
    {
        $request = Request::create('/api/v1/auth/login', 'POST', server: ['REMOTE_ADDR' => $ip]);
        $request->attributes->set(SecurityRequestAttributes::LAST_USERNAME, $email);

        return $request;
    }
}
