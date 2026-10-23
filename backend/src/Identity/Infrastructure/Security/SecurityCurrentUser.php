<?php

declare(strict_types=1);

namespace App\Identity\Infrastructure\Security;

use App\Identity\Api\CurrentUser;
use Symfony\Bundle\SecurityBundle\Security;
use Symfony\Component\Uid\Uuid;

final readonly class SecurityCurrentUser implements CurrentUser
{
    public function __construct(private Security $security)
    {
    }

    public function id(): ?Uuid
    {
        $user = $this->security->getUser();

        return $user instanceof SecurityUser ? $user->id() : null;
    }
}
