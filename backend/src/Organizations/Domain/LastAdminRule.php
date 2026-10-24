<?php

declare(strict_types=1);

namespace App\Organizations\Domain;

/**
 * FCRM-002 BR-03: an organization always keeps at least one active ADMIN.
 * A change violates the rule when it demotes or removes an active ADMIN
 * while no other active ADMIN exists. The caller counts the active ADMINs
 * (the target included) under the organization lock, so the count cannot
 * change before the change is written (ADR-020).
 */
final class LastAdminRule
{
    /**
     * @param MembershipRole|null $newRole      the role after the change; null for a removal
     * @param int                 $activeAdmins the organization's active ADMIN memberships, the target included
     */
    public static function violatedBy(Membership $target, ?MembershipRole $newRole, int $activeAdmins): bool
    {
        if (MembershipStatus::Active !== $target->status() || MembershipRole::Admin !== $target->role()) {
            return false;
        }
        if (MembershipRole::Admin === $newRole) {
            return false;
        }

        return $activeAdmins < 2;
    }
}
