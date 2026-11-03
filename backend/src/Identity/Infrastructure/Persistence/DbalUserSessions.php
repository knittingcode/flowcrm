<?php

declare(strict_types=1);

namespace App\Identity\Infrastructure\Persistence;

use App\Identity\Application\UserSessions;
use Doctrine\DBAL\Connection;
use Symfony\Component\Uid\Uuid;

/**
 * Deletes the user's rows from the PostgreSQL session store
 * (PdoSessionHandler, config/packages/session.yaml) on the default
 * connection, so in the same transaction as the change that ends them.
 *
 * The table has no user column: a session belongs to a user when its data
 * holds the user's ID, which the serialized security token always does
 * (SecurityUser::__serialize). Only logged-in sessions are stored, and each
 * holds its own user's ID and random tokens, never another user's ID.
 * A request that holds a session row's lock (LOCK_TRANSACTIONAL) is waited
 * for, so its write cannot bring the row back afterwards.
 */
final readonly class DbalUserSessions implements UserSessions
{
    public function __construct(private Connection $connection)
    {
    }

    public function endAll(Uuid $userId): void
    {
        $this->connection->executeStatement(
            "DELETE FROM sessions WHERE position(convert_to(?, 'UTF8') IN sess_data) > 0",
            [$userId->toRfc4122()],
        );
    }
}
