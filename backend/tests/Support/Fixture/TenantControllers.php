<?php

declare(strict_types=1);

namespace App\Tests\Support\Fixture;

use App\Organizations\Domain\Permission;
use App\Organizations\Http\Tenant\TenantPermission;

/** Controllers for TenantGuardTest: correct and incorrectly declared policies. */
final class TenantControllers
{
    #[TenantPermission(Permission::MembershipViewEmail)]
    public function declared(): void
    {
    }

    public function undeclared(): void
    {
    }

    #[TenantPermission(Permission::OrganizationView)]
    #[TenantPermission(Permission::MembershipList)]
    public function twice(): void
    {
    }
}
