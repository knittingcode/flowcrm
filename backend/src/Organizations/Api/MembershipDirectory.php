<?php

declare(strict_types=1);

namespace App\Organizations\Api;

use Symfony\Component\Uid\Uuid;

interface MembershipDirectory
{
    /**
     * The user's active memberships, ordered by organization name; removed
     * memberships are not listed.
     *
     * @return list<MembershipSummary>
     */
    public function activeMembershipsOf(Uuid $userId): array;
}
