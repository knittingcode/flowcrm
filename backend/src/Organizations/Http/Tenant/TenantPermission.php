<?php

declare(strict_types=1);

namespace App\Organizations\Http\Tenant;

use App\Organizations\Domain\Permission;

/**
 * The permission a tenant route requires (FCRM-002 NFR-002: every endpoint
 * declares one). TenantGuard refuses to run a tenant route without exactly
 * one, and TenantRouteRegistryTest fails for such a route.
 */
#[\Attribute(\Attribute::TARGET_METHOD | \Attribute::IS_REPEATABLE)]
final readonly class TenantPermission
{
    public function __construct(public Permission $permission)
    {
    }
}
