<?php

declare(strict_types=1);

namespace App\Organizations\Api;

use Symfony\Component\Uid\Uuid;

final readonly class MembershipSummary
{
    /**
     * @param list<string> $permissions what the role may do (FCRM-002 REQ-005: for showing controls only)
     */
    public function __construct(
        public Uuid $organizationId,
        public string $organizationName,
        public Uuid $membershipId,
        public string $role,
        public array $permissions,
    ) {
    }
}
