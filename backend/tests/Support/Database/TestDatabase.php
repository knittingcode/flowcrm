<?php

declare(strict_types=1);

namespace App\Tests\Support\Database;

use Doctrine\DBAL\Configuration;
use Doctrine\DBAL\Connection;
use Doctrine\DBAL\DriverManager;

/**
 * Connections of the test suite besides the kernel's own (which uses the
 * runtime role flowcrm_app, like the API): the schema owner, for schema
 * changes and migration history, and the bootstrap superuser, for creating
 * databases and roles. Their passwords exist only in the test project's api
 * container (compose.test.yaml); the dev and prod api never get them.
 */
final class TestDatabase
{
    public const OWNER = 'flowcrm_owner';

    public static function owner(?string $database = null, ?Configuration $configuration = null): Connection
    {
        return self::connect(self::OWNER, self::env('FLOWCRM_TEST_OWNER_PASSWORD_FILE'), $database, $configuration);
    }

    public static function admin(?string $database = null): Connection
    {
        return self::connect('flowcrm', self::env('FLOWCRM_TEST_ADMIN_PASSWORD_FILE'), $database, null);
    }

    /**
     * Environment for a bin/console process that runs as the owner.
     *
     * @return array<string, string>
     */
    public static function ownerProcessEnv(): array
    {
        return ['DATABASE_USER' => self::OWNER, 'DATABASE_PASSWORD_FILE' => self::env('FLOWCRM_TEST_OWNER_PASSWORD_FILE')];
    }

    private static function connect(string $user, string $passwordFile, ?string $database, ?Configuration $configuration): Connection
    {
        return DriverManager::getConnection([
            'driver' => 'pdo_pgsql',
            'host' => self::env('DATABASE_HOST'),
            'port' => (int) self::env('DATABASE_PORT'),
            'dbname' => $database ?? self::env('DATABASE_NAME'),
            'user' => $user,
            'password' => trim((string) file_get_contents($passwordFile)),
            'serverVersion' => '18',
        ], $configuration);
    }

    private static function env(string $name): string
    {
        $value = $_SERVER[$name] ?? $_ENV[$name] ?? getenv($name);
        if (!\is_string($value) || '' === $value) {
            throw new \LogicException($name.' is not set (the test project provides it, compose.test.yaml)');
        }

        return $value;
    }
}
