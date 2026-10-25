<?php

declare(strict_types=1);

namespace App\Organizations\Domain;

/**
 * The static role-to-permission map of the organization module (FCRM-002
 * section H: no dynamic permission engine), the single source of truth for
 * the voter and for the permissions shown to the SPA.
 *
 * Provisional matrix of FCRM-FND-010B (ADR-019), with the membership
 * administration of FCRM-FND-010C (ADR-020):
 *
 * | Permission              | ADMIN | MANAGER | REP | Source                     |
 * |-------------------------|-------|---------|-----|----------------------------|
 * | organization.view       | yes   | yes     | yes | FCRM-002 H [TASK]          |
 * | membership.list         | yes   | yes     | yes | FCRM-002 H [PROP]          |
 * | membership.view_email   | yes   | yes     | no  | provisional (not in H)     |
 * | membership.add          | yes   | no      | no  | FCRM-002 H [TASK]          |
 * | membership.change_role  | yes   | no      | no  | FCRM-002 H [TASK]          |
 * | membership.remove       | yes   | no      | no  | FCRM-002 H [TASK]          |
 *
 * Each role lists its permissions explicitly: no role inherits another
 * role's permissions, and anything missing is denied.
 */
final class RolePolicy
{
    private const GRANTS = [
        'ADMIN' => [
            Permission::OrganizationView,
            Permission::MembershipList,
            Permission::MembershipViewEmail,
            Permission::MembershipAdd,
            Permission::MembershipChangeRole,
            Permission::MembershipRemove,
        ],
        'MANAGER' => [Permission::OrganizationView, Permission::MembershipList, Permission::MembershipViewEmail],
        'REP' => [Permission::OrganizationView, Permission::MembershipList],
    ];

    public static function grants(MembershipRole $role, Permission $permission): bool
    {
        return \in_array($permission, self::GRANTS[$role->value], true);
    }

    /** @return list<Permission> */
    public static function permissionsOf(MembershipRole $role): array
    {
        return self::GRANTS[$role->value];
    }
}
