<?php

declare(strict_types=1);

namespace App\Organizations\Application;

use App\Organizations\Api\TenantContext;
use Symfony\Component\Uid\Uuid;

/**
 * Tenant-scoped reads. Every query takes the organization and filters by
 * it in SQL: there is no lookup of a tenant object by its ID alone.
 */
interface OrganizationReadModel
{
    /** The user's ACTIVE membership in the organization; null for none, a removed one or an unknown organization. */
    public function activeMembership(Uuid $organizationId, Uuid $userId): ?TenantContext;

    public function organization(Uuid $organizationId): ?OrganizationView;

    /**
     * Active members, oldest membership first.
     *
     * @return array{list<MemberRow>, int} the page and the total
     */
    public function members(Uuid $organizationId, int $offset, int $limit): array;

    /** An active member of this organization; null when the ID belongs to another organization. */
    public function member(Uuid $organizationId, Uuid $membershipId): ?MemberRow;
}
