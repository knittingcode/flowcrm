<?php

declare(strict_types=1);

namespace App\CRM\Domain;

/**
 * The editable details of an account, normalised and valid: surrounding
 * white space is removed and an empty optional value is null. Every text is
 * valid UTF-8 without control characters, so PostgreSQL can store it.
 */
final readonly class AccountDetails
{
    public const NAME_MAX = 200;
    public const WEBSITE_MAX = 2048;
    public const EMAIL_MAX = 254;
    public const PHONE_MAX = 50;

    private function __construct(
        public string $name,
        public ?string $website,
        public ?string $email,
        public ?string $phone,
    ) {
    }

    /** @throws InvalidAccountDetails */
    public static function of(string $name, ?string $website = null, ?string $email = null, ?string $phone = null): self
    {
        $values = ['name' => $name, 'website' => $website, 'email' => $email, 'phone' => $phone];
        $violations = [];
        foreach ($values as $field => $value) {
            if (null === $value) {
                continue;
            }
            $trimmed = mb_check_encoding($value, 'UTF-8') ? trim($value) : null;
            if (null === $trimmed || 1 === preg_match('/\p{Cc}/u', $trimmed)) {
                $violations[$field] = 'INVALID_CHARACTERS';
                $values[$field] = null;

                continue;
            }
            $values[$field] = '' === $trimmed ? null : $trimmed;
        }

        $name = $values['name'];
        if (!isset($violations['name'])) {
            if (null === $name) {
                $violations['name'] = 'BLANK';
            } elseif (mb_strlen($name) > self::NAME_MAX) {
                $violations['name'] = 'TOO_LONG';
            }
        }
        $website = $values['website'];
        if (null !== $website) {
            if (\strlen($website) > self::WEBSITE_MAX) {
                $violations['website'] = 'TOO_LONG';
            } elseif (!self::isHttpUrl($website)) {
                $violations['website'] = 'INVALID_URL';
            }
        }
        $email = $values['email'];
        if (null !== $email) {
            if (\strlen($email) > self::EMAIL_MAX) {
                $violations['email'] = 'TOO_LONG';
            } elseif (false === filter_var($email, \FILTER_VALIDATE_EMAIL, \FILTER_FLAG_EMAIL_UNICODE)) {
                $violations['email'] = 'INVALID_EMAIL';
            }
        }
        $phone = $values['phone'];
        if (null !== $phone) {
            if (mb_strlen($phone) > self::PHONE_MAX) {
                $violations['phone'] = 'TOO_LONG';
            } elseif (1 !== preg_match('~^\+?[0-9][0-9 ()./-]{2,}$~', $phone)) {
                $violations['phone'] = 'INVALID_PHONE';
            }
        }
        if ([] !== $violations) {
            throw new InvalidAccountDetails($violations);
        }
        \assert(null !== $name);

        return new self($name, $website, $email, $phone);
    }

    /** An absolute http or https URL with a host. */
    private static function isHttpUrl(string $value): bool
    {
        if (1 === preg_match('/\s/', $value)) {
            return false;
        }
        $parts = parse_url($value);

        return \is_array($parts)
            && \in_array(strtolower($parts['scheme'] ?? ''), ['http', 'https'], true)
            && '' !== ($parts['host'] ?? '')
            && !isset($parts['user'], $parts['pass']);
    }
}
