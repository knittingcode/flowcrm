<?php

declare(strict_types=1);

namespace App\CRM\Application;

use Symfony\Component\Uid\Uuid;

/**
 * Tenant-scoped reads of accounts. Every query takes the organization and
 * filters by it in SQL: there is no lookup of an account by its ID alone.
 */
interface AccountReadModel
{
    /**
     * Accounts that are not archived, by name (regardless of case), then by ID.
     *
     * @return array{list<AccountView>, int} the page and the total
     */
    public function page(Uuid $organizationId, int $offset, int $limit): array;

    /** An account of this organization, archived or not; null when the ID belongs to another organization. */
    public function account(Uuid $organizationId, Uuid $accountId): ?AccountView;
}
