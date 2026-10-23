<?php

declare(strict_types=1);

namespace App\Identity\Infrastructure\Security;

use Symfony\Component\DependencyInjection\Attribute\Autowire;
use Symfony\Component\HttpFoundation\RateLimiter\AbstractRequestRateLimiter;
use Symfony\Component\HttpFoundation\Request;
use Symfony\Component\RateLimiter\LimiterInterface;
use Symfony\Component\RateLimiter\RateLimiterFactoryInterface;
use Symfony\Component\Security\Http\SecurityRequestAttributes;

/**
 * Layered login throttling (ADR-019), used by the firewall's
 * login_throttling: the limits are checked before the password is hashed
 * and only failed logins count.
 *
 * - account and client IP: 5 per 15 minutes (brute force from one client);
 * - client IP: 50 per 15 minutes (password spraying over many accounts);
 * - account: 100 per day from any IP (distributed attacks on one account).
 *
 * Unknown accounts count like known ones, so the limits reveal nothing. The
 * client IP is Request::getClientIp(), which trusts only the edge's
 * X-Forwarded-For (framework.yaml); a client cannot choose its own. Keys
 * are HMACs: neither an e-mail address nor an IP address is stored.
 *
 * A successful login clears only the account-and-IP limit: the IP limit
 * must survive the login of an attacker's own account, and the account limit
 * the login of its owner while an attack goes on.
 */
final class LoginRateLimiter extends AbstractRequestRateLimiter
{
    public function __construct(
        #[Autowire(service: 'flowcrm.rate_limiter.login_account_ip')]
        private readonly RateLimiterFactoryInterface $accountAndIp,
        #[Autowire(service: 'flowcrm.rate_limiter.login_ip')]
        private readonly RateLimiterFactoryInterface $ip,
        #[Autowire(service: 'flowcrm.rate_limiter.login_account')]
        private readonly RateLimiterFactoryInterface $account,
        #[Autowire('%kernel.secret%')]
        #[\SensitiveParameter]
        private readonly string $secret,
    ) {
    }

    public function reset(Request $request): void
    {
        $this->accountAndIpLimiter($request)->reset();
    }

    protected function getLimiters(Request $request): array
    {
        return [
            $this->accountAndIpLimiter($request),
            $this->ip->create($this->key('ip', (string) $request->getClientIp())),
            $this->account->create($this->key('account', self::account($request))),
        ];
    }

    private function accountAndIpLimiter(Request $request): LimiterInterface
    {
        return $this->accountAndIp->create($this->key('account-ip', self::account($request)."\0".$request->getClientIp()));
    }

    private static function account(Request $request): string
    {
        $email = $request->attributes->get(SecurityRequestAttributes::LAST_USERNAME, '');
        $email = \is_string($email) ? $email : '';

        return mb_check_encoding($email, 'UTF-8') ? mb_strtolower($email, 'UTF-8') : strtolower($email);
    }

    private function key(string $limit, string $value): string
    {
        return $limit.'-'.hash_hmac('sha256', $value, $this->secret);
    }
}
