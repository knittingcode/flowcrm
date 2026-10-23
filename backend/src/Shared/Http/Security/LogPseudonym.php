<?php

declare(strict_types=1);

namespace App\Shared\Http\Security;

use Symfony\Component\DependencyInjection\Attribute\Autowire;

/**
 * Keyed pseudonyms for security log records: the same e-mail address or IP
 * address always gives the same reference, so related events can be
 * correlated within the log retention, but the value itself is never
 * written (FCRM-FND-010B privacy constraint). HMAC-SHA256 with the
 * application secret, truncated to 64 bits.
 */
final readonly class LogPseudonym
{
    public function __construct(
        #[Autowire('%kernel.secret%')]
        #[\SensitiveParameter]
        private string $secret,
    ) {
    }

    public function of(?string $value): ?string
    {
        if (null === $value || '' === $value) {
            return null;
        }

        return substr(hash_hmac('sha256', $value, $this->secret), 0, 16);
    }
}
