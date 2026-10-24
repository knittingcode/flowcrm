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
 * client IP is Request::getClientIp(): the address the edge passes as
 * REMOTE_ADDR, with no proxy trusted (compose.yaml); a client cannot choose
 * its own. Keys
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

    /**
     * The account part of the keys. It must fold case at least as far as the
     * user lookup, PostgreSQL lower(email) = lower(?): every spelling that
     * loads the same account must give the same key, or each spelling would
     * get windows of its own. lower() maps one character to one character,
     * so this uses the simple Unicode mapping; the full mapping
     * (mb_strtolower) turns U+0130 into "i" + U+0307 and a final capital
     * sigma into U+03C2, while lower() gives "i" and U+03C3. Checked against
     * every code point for the database locale (libc, en_US.utf8): no two
     * spellings that lower() folds together get different keys. The reverse
     * does not hold for 124 code points (circled letters such as U+24B6, for
     * example), which this folds and lower() does not; those spellings share
     * the account's windows without loading it, which only makes the limit
     * stricter. A change of the database locale, collation provider, C
     * library or PHP's Unicode tables needs this check again.
     */
    private static function account(Request $request): string
    {
        $email = $request->attributes->get(SecurityRequestAttributes::LAST_USERNAME, '');
        $email = \is_string($email) ? $email : '';

        return mb_check_encoding($email, 'UTF-8') ? mb_convert_case($email, \MB_CASE_LOWER_SIMPLE, 'UTF-8') : strtolower($email);
    }

    private function key(string $limit, string $value): string
    {
        return $limit.'-'.hash_hmac('sha256', $value, $this->secret);
    }
}
