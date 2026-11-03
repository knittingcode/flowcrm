<?php

declare(strict_types=1);

namespace App\Identity\Infrastructure\Security;

use App\Identity\Application\CurrentSession;
use App\Identity\Domain\UserRepository;
use Symfony\Component\DependencyInjection\Attribute\Autowire;
use Symfony\Component\HttpFoundation\RequestStack;
use Symfony\Component\Security\Core\Authentication\Token\Storage\TokenStorageInterface;

final readonly class SessionCredentials implements CurrentSession
{
    public function __construct(
        private TokenStorageInterface $tokens,
        private RequestStack $requests,
        private UserRepository $users,
        #[Autowire('%env(int:FLOWCRM_SESSION_ABSOLUTE_LIFETIME)%')]
        private int $absoluteLifetime,
    ) {
    }

    public function expiresAt(): ?\DateTimeImmutable
    {
        $user = $this->tokens->getToken()?->getUser();

        return $user instanceof SecurityUser ? new \DateTimeImmutable('@'.($user->authenticatedAt() + $this->absoluteLifetime)) : null;
    }

    public function credentialsChanged(): void
    {
        $token = $this->tokens->getToken();
        $user = $token?->getUser();
        if (null === $token || !$user instanceof SecurityUser) {
            throw new \LogicException('No logged-in user.');
        }
        $current = $this->users->ofId($user->id()) ?? throw new \LogicException('The user is gone.');

        // The login time (absolute lifetime) is kept; the new fingerprint keeps
        // this session valid, while every other session no longer matches.
        $token->setUser(SecurityUser::fromUser($current, $user->authenticatedAt()));
        $this->requests->getMainRequest()?->getSession()->migrate(true);
    }
}
