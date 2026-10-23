<?php

declare(strict_types=1);

namespace App\Identity\Domain;

/**
 * FCRM-002 NFR-001: 12 to 128 characters (Unicode code points), no
 * composition rules. The text is not normalised.
 */
final class PasswordPolicy
{
    public const MIN_LENGTH = 12;
    public const MAX_LENGTH = 128;

    /**
     * The violated rules, empty when the password is acceptable.
     *
     * @return list<'PASSWORD_INVALID'|'PASSWORD_TOO_SHORT'|'PASSWORD_TOO_LONG'>
     */
    public static function violations(string $password): array
    {
        if (!mb_check_encoding($password, 'UTF-8')) {
            return ['PASSWORD_INVALID'];
        }
        $length = mb_strlen($password, 'UTF-8');
        if ($length < self::MIN_LENGTH) {
            return ['PASSWORD_TOO_SHORT'];
        }
        if ($length > self::MAX_LENGTH) {
            return ['PASSWORD_TOO_LONG'];
        }

        return [];
    }
}
