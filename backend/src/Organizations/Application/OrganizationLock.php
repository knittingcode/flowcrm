<?php

declare(strict_types=1);

namespace App\Organizations\Application;

use Symfony\Component\Uid\Uuid;

/**
 * Serialises the membership changes of one organization (ADR-020): the lock
 * is held until the surrounding transaction ends, so every check made after
 * it (the actor's own membership, the number of active ADMINs) stays true
 * until the change and its audit event are committed.
 */
interface OrganizationLock
{
    /**
     * Must run inside a transaction (Transaction::run).
     *
     * @return bool false when the organization does not exist
     */
    public function lock(Uuid $organizationId): bool;
}
