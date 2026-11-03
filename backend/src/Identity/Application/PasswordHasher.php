<?php

declare(strict_types=1);

namespace App\Identity\Application;

interface PasswordHasher
{
    public function hash(#[\SensitiveParameter] string $password): string;

    public function verify(string $hash, #[\SensitiveParameter] string $password): bool;
}
