<?php

declare(strict_types=1);

namespace App\Identity\Infrastructure\Security;

use App\Identity\Application\PasswordHasher;
use Symfony\Component\PasswordHasher\Hasher\PasswordHasherFactoryInterface;

/** The hasher configured for SecurityUser in security.yaml (Argon2id). */
final readonly class SymfonyPasswordHasher implements PasswordHasher
{
    public function __construct(private PasswordHasherFactoryInterface $hashers)
    {
    }

    public function hash(#[\SensitiveParameter] string $password): string
    {
        return $this->hashers->getPasswordHasher(SecurityUser::class)->hash($password);
    }

    public function verify(string $hash, #[\SensitiveParameter] string $password): bool
    {
        return $this->hashers->getPasswordHasher(SecurityUser::class)->verify($hash, $password);
    }
}
