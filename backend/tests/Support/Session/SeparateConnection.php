<?php

declare(strict_types=1);

namespace App\Tests\Support\Session;

/**
 * A PDO connection of its own to the test database, as another request or
 * another PHP-FPM worker would have: used to hold locks and to observe the
 * session connections (application_name flowcrm_sessions).
 */
final class SeparateConnection
{
    public static function open(): \PDO
    {
        return new \PDO(
            \sprintf('pgsql:host=%s;port=%s;dbname=%s', self::env('DATABASE_HOST'), self::env('DATABASE_PORT'), self::env('DATABASE_NAME')),
            self::env('DATABASE_USER'),
            trim((string) file_get_contents(self::env('DATABASE_PASSWORD_FILE'))),
            [\PDO::ATTR_ERRMODE => \PDO::ERRMODE_EXCEPTION],
        );
    }

    /** Open connections of the session handler, polled for up to two seconds until none is left. */
    public static function sessionConnectionsAfterRequests(\PDO $observer): int
    {
        for ($i = 0;; ++$i) {
            $statement = $observer->query("SELECT count(*) FROM pg_stat_activity WHERE application_name = 'flowcrm_sessions'");
            $count = false === $statement ? -1 : (int) $statement->fetchColumn();
            if (0 === $count || $i >= 20) {
                return $count;
            }
            usleep(100_000);
        }
    }

    /** The configuration the kernel sees (.env and the container environment). */
    private static function env(string $name): string
    {
        $value = $_SERVER[$name] ?? $_ENV[$name] ?? null;
        if (!\is_string($value)) {
            throw new \LogicException($name.' is not set');
        }

        return $value;
    }
}
