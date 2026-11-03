<?php

declare(strict_types=1);

namespace App\Identity\Api;

use Symfony\Component\Uid\Uuid;

final readonly class UserProfile
{
    public function __construct(
        public Uuid $id,
        public string $email,
        public string $displayName,
    ) {
    }
}
