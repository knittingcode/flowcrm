<?php

declare(strict_types=1);

namespace App\Organizations\Infrastructure\Persistence;

use App\Organizations\Application\OrganizationLock;
use Doctrine\DBAL\Connection;
use Symfony\Component\Uid\Uuid;

/**
 * A row lock on the organization (SELECT ... FOR NO KEY UPDATE) on the default
 * connection, which the entity manager and the audit trail share: the lock
 * belongs to the same transaction as the change and its audit event and is
 * released by its commit or rollback. NO KEY UPDATE conflicts with itself
 * but not with the KEY SHARE locks of foreign key checks, so rows that
 * reference the organization can still be inserted meanwhile. flowcrm_app
 * holds UPDATE on organizations (ADR-018), which the lock requires.
 */
final readonly class DbalOrganizationLock implements OrganizationLock
{
    public function __construct(private Connection $connection)
    {
    }

    public function lock(Uuid $organizationId): bool
    {
        if (!$this->connection->isTransactionActive()) {
            throw new \LogicException('The organization lock needs a transaction: outside one it would end with the statement.');
        }

        return false !== $this->connection->fetchOne('SELECT id FROM organizations WHERE id = ? FOR NO KEY UPDATE', [$organizationId->toRfc4122()]);
    }
}
