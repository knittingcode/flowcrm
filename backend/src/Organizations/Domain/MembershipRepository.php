<?php

declare(strict_types=1);

namespace App\Organizations\Domain;

use Symfony\Component\Uid\Uuid;

interface MembershipRepository
{
    public function add(Membership $membership): void;

    /** Any membership of the user in the organization, also a removed one (one per pair). */
    public function ofOrganizationAndUser(Uuid $organizationId, Uuid $userId): ?Membership;

    /** A membership of this organization, also a removed one; null when the ID belongs to another organization. */
    public function ofOrganizationAndId(Uuid $organizationId, Uuid $membershipId): ?Membership;

    /** The organization's ACTIVE memberships with the role ADMIN. */
    public function activeAdminCount(Uuid $organizationId): int;
}
