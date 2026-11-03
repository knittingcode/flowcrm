<?php

declare(strict_types=1);

namespace App\Tests\Unit\Organizations;

use App\Organizations\Domain\MembershipRole;
use App\Organizations\Domain\Permission;
use App\Organizations\Domain\RolePolicy;
use PHPUnit\Framework\TestCase;

/** The provisional matrix of FND-010B as test data (FCRM-003 FND-009: "RBAC matrix definition as test data"). */
final class RolePolicyTest extends TestCase
{
    private const MATRIX = [
        'organization.view' => ['ADMIN' => true, 'MANAGER' => true, 'REP' => true],
        'membership.list' => ['ADMIN' => true, 'MANAGER' => true, 'REP' => true],
        'membership.view_email' => ['ADMIN' => true, 'MANAGER' => true, 'REP' => false],
    ];

    public function testEveryCellOfTheMatrix(): void
    {
        foreach (Permission::cases() as $permission) {
            self::assertArrayHasKey($permission->value, self::MATRIX, 'no permission without a row');
        }
        foreach (self::MATRIX as $permission => $roles) {
            foreach (MembershipRole::cases() as $role) {
                self::assertSame($roles[$role->value], RolePolicy::grants($role, Permission::from($permission)), "$permission for {$role->value}");
            }
        }
    }

    public function testThePermissionListsMatchTheGrants(): void
    {
        foreach (MembershipRole::cases() as $role) {
            $listed = array_map(static fn (Permission $p): string => $p->value, RolePolicy::permissionsOf($role));
            $granted = array_keys(array_filter(self::MATRIX, static fn (array $roles): bool => $roles[$role->value]));
            self::assertSame($granted, $listed, $role->value);
        }
    }
}
