<?php

declare(strict_types=1);

namespace App\Organizations\Domain;

use Symfony\Component\Uid\Uuid;

interface MembershipRepository
{
    public function add(Membership $membership): void;

    /** Any membership of the user in the organization, also a removed one (one per pair). */
    public function ofOrganizationAndUser(Uuid $organizationId, Uuid $userId): ?Membership;
}
