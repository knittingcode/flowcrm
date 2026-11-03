<?php

declare(strict_types=1);

namespace App\Shared\Infrastructure\Cache;

use Doctrine\Bundle\DoctrineBundle\Attribute\AsMiddleware;
use Doctrine\DBAL\Driver;
use Doctrine\DBAL\Driver\Connection;
use Doctrine\DBAL\Driver\Middleware;
use Doctrine\DBAL\Driver\Middleware\AbstractConnectionMiddleware;
use Doctrine\DBAL\Driver\Middleware\AbstractDriverMiddleware;
use Doctrine\DBAL\Driver\Result;
use Doctrine\DBAL\Driver\Statement;

/**
 * Keeps the cache connection from changing the schema. Symfony's
 * DoctrineDbalAdapter creates its table when it is missing; with this
 * middleware that attempt fails (the cache logs it and treats the item as
 * a miss), so cache_items exists only once its migration has run.
 *
 * It guards against the adapter's own statements, not against hostile SQL.
 */
#[AsMiddleware(connections: ['cache'])]
final class RejectSchemaChanges implements Middleware
{
    private const SCHEMA_CHANGE = '/^\s*(CREATE|ALTER|DROP|TRUNCATE)\b/i';

    public function wrap(Driver $driver): Driver
    {
        return new class($driver) extends AbstractDriverMiddleware {
            public function connect(#[\SensitiveParameter] array $params): Connection
            {
                return new class(parent::connect($params)) extends AbstractConnectionMiddleware {
                    public function prepare(string $sql): Statement
                    {
                        return parent::prepare(RejectSchemaChanges::check($sql));
                    }

                    public function query(string $sql): Result
                    {
                        return parent::query(RejectSchemaChanges::check($sql));
                    }

                    public function exec(string $sql): int|string
                    {
                        return parent::exec(RejectSchemaChanges::check($sql));
                    }
                };
            }
        };
    }

    /** @throws SchemaChangeRejected */
    public static function check(string $sql): string
    {
        if (1 === preg_match(self::SCHEMA_CHANGE, $sql, $match)) {
            throw new SchemaChangeRejected(\sprintf('The cache connection does not change the schema (%s rejected); the table comes from a migration.', strtoupper($match[1])));
        }

        return $sql;
    }
}
