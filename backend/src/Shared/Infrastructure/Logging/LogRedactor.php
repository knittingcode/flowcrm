<?php

declare(strict_types=1);

namespace App\Shared\Infrastructure\Logging;

use Doctrine\DBAL\Driver\Exception as DriverError;
use Doctrine\DBAL\Exception\DriverException;

/**
 * Removes secrets and personal data from log data (FCRM-003 section Q):
 * values under sensitive keys, credentials written into free text, and the
 * messages of database driver errors, which can quote row values.
 */
final class LogRedactor
{
    public const MASK = '[redacted]';

    /** Keys whose values are never logged, compared case-insensitively. */
    private const KEYS = [
        'password', 'passwd', 'pwd', 'secret', 'token', 'csrf', 'authorization',
        'cookie', 'set-cookie', 'session', 'sid', 'sess_id', 'sess_data', 'api_key', 'apikey',
        'email', 'phone', 'first_name', 'last_name', 'display_name',
    ];

    /** Key fragments that mark a key as sensitive (for example access_token, x-csrf-token). */
    private const FRAGMENTS = ['password', 'secret', 'token', 'csrf', 'cookie', 'session', 'authorization'];

    private const MAX_DEPTH = 8;

    public static function isSensitiveKey(string $key): bool
    {
        $key = strtolower($key);
        if (\in_array($key, self::KEYS, true)) {
            return true;
        }
        foreach (self::FRAGMENTS as $fragment) {
            if (str_contains($key, $fragment)) {
                return true;
            }
        }

        return false;
    }

    /**
     * @param array<array-key, mixed> $data
     *
     * @return array<array-key, mixed>
     */
    public static function redact(array $data, int $depth = 0): array
    {
        $result = [];
        foreach ($data as $key => $value) {
            if (\is_string($key) && self::isSensitiveKey($key)) {
                $result[$key] = self::MASK;
            } elseif ($value instanceof \Throwable) {
                $result[$key] = self::exception($value);
            } elseif (\is_array($value)) {
                $result[$key] = $depth >= self::MAX_DEPTH ? '[too deep]' : self::redact($value, $depth + 1);
            } elseif (\is_string($value)) {
                $result[$key] = self::scrub($value);
            } elseif (null === $value || \is_scalar($value)) {
                $result[$key] = $value;
            } elseif ($value instanceof \Stringable) {
                $result[$key] = self::scrub((string) $value);
            } else {
                $result[$key] = '['.get_debug_type($value).']';
            }
        }

        return $result;
    }

    /**
     * Masks credentials written as text: key=value or key: value pairs with a
     * sensitive key, bearer tokens and passwords in URLs.
     */
    public static function scrub(string $text): string
    {
        $text = (string) preg_replace('~\b((?:[\w-]*(?:password|passwd|pwd|secret|token|api[_-]?key|session|cookie|csrf))\b["\']?\s*[=:]\s*)("[^"]*"|\'[^\']*\'|[^\s,;&"\']+)~i', '$1'.self::MASK, $text);
        $text = (string) preg_replace('#\b(Bearer|Basic)\s+[A-Za-z0-9._~+/=-]+#i', '$1 '.self::MASK, $text);

        return (string) preg_replace('~([a-z][a-z0-9+.-]*://[^\s:/@]+:)[^\s@/]+@~i', '$1'.self::MASK.'@', $text);
    }

    /**
     * @return array{class: string, message: string, code: int|string, file: string, previous?: array<string, mixed>}
     */
    public static function exception(\Throwable $e, int $depth = 0): array
    {
        $data = [
            'class' => $e::class,
            'message' => self::exceptionMessage($e),
            'code' => $e->getCode(),
            'file' => $e->getFile().':'.$e->getLine(),
        ];
        $previous = $e->getPrevious();
        if (null !== $previous && $depth < 5) {
            $data['previous'] = self::exception($previous, $depth + 1);
        }

        return $data;
    }

    /**
     * The message of an exception as it may be logged. Database driver
     * errors are reduced to their SQLSTATE: their text can contain row
     * values (for example "Key (email)=(…) already exists"); this covers the
     * DBAL exceptions, the driver exceptions they wrap and PDOException.
     */
    public static function exceptionMessage(\Throwable $e): string
    {
        if ($e instanceof DriverException || $e instanceof DriverError) {
            return \sprintf('database error (SQLSTATE %s)', $e->getSQLState() ?? 'unknown');
        }
        if ($e instanceof \PDOException) {
            return \sprintf('database error (SQLSTATE %s)', \is_array($e->errorInfo) && \is_string($e->errorInfo[0] ?? null) ? $e->errorInfo[0] : 'unknown');
        }

        return self::scrub($e->getMessage());
    }

    /**
     * Replaces the raw messages of the exception chain in a log message (the
     * framework writes them into its "Uncaught PHP Exception" line).
     */
    public static function withoutRawMessages(string $message, \Throwable $e): string
    {
        for ($current = $e, $depth = 0; null !== $current && $depth < 6; $current = $current->getPrevious(), ++$depth) {
            $raw = $current->getMessage();
            if ('' !== $raw) {
                $message = str_replace($raw, self::exceptionMessage($current), $message);
            }
        }

        return self::scrub($message);
    }
}
