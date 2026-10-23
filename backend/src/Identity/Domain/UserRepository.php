<?php

declare(strict_types=1);

namespace App\Identity\Domain;

use Symfony\Component\Uid\Uuid;

interface UserRepository
{
    public function ofId(Uuid $id): ?User;

    /** Case-insensitive, with the same lower() as the unique index. */
    public function ofEmail(string $email): ?User;

    public function add(User $user): void;
}
