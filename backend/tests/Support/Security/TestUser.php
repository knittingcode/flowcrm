<?php

declare(strict_types=1);

namespace App\Tests\Support\Security;

use Symfony\Component\Uid\Uuid;

final readonly class TestUser
{
    public function __construct(
        public Uuid $id,
        public string $email,
        #[\SensitiveParameter]
        public string $password,
        public string $displayName,
    ) {
    }
}
