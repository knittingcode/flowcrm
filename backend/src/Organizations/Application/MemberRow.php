<?php

declare(strict_types=1);

namespace App\Organizations\Application;

use Symfony\Component\Uid\Uuid;

final readonly class MemberRow
{
    public function __construct(
        public Uuid $membershipId,
        public Uuid $userId,
        public string $role,
    ) {
    }
}
