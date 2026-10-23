<?php

declare(strict_types=1);

namespace App\Organizations\Application;

use Symfony\Component\Uid\Uuid;

final readonly class MemberView
{
    public function __construct(
        public Uuid $membershipId,
        public Uuid $userId,
        public string $displayName,
        public string $email,
        public string $role,
    ) {
    }
}
