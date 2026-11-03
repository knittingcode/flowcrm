<?php

declare(strict_types=1);

namespace App\Identity\Infrastructure\Security;

use Symfony\Component\Security\Core\Authentication\Token\TokenInterface;
use Symfony\Component\Security\Core\Exception\DisabledException;
use Symfony\Component\Security\Core\User\UserCheckerInterface;
use Symfony\Component\Security\Core\User\UserInterface;

/**
 * A disabled user cannot log in. Checked after the password (post-auth), so
 * a disabled account costs the same as any other and its response is the
 * generic failure: it does not reveal that the password was right.
 */
final readonly class UserChecker implements UserCheckerInterface
{
    public function checkPreAuth(UserInterface $user): void
    {
    }

    public function checkPostAuth(UserInterface $user, ?TokenInterface $token = null): void
    {
        if ($user instanceof SecurityUser && $user->isDisabled()) {
            throw new DisabledException();
        }
    }
}
