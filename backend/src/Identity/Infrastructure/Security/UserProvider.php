<?php

declare(strict_types=1);

namespace App\Identity\Infrastructure\Security;

use App\Identity\Domain\UserRepository;
use App\Shared\Application\Transaction;
use Psr\Clock\ClockInterface;
use Symfony\Component\DependencyInjection\Attribute\Autowire;
use Symfony\Component\PasswordHasher\Hasher\PasswordHasherFactoryInterface;
use Symfony\Component\Security\Core\Exception\UnsupportedUserException;
use Symfony\Component\Security\Core\Exception\UserNotFoundException;
use Symfony\Component\Security\Core\User\PasswordAuthenticatedUserInterface;
use Symfony\Component\Security\Core\User\PasswordUpgraderInterface;
use Symfony\Component\Security\Core\User\UserInterface;
use Symfony\Component\Security\Core\User\UserProviderInterface;

/**
 * Loads users for the firewall: by e-mail address at login (case-insensitive,
 * with the lower() of the unique index), by ID on every later request.
 *
 * @implements UserProviderInterface<SecurityUser>
 */
final readonly class UserProvider implements UserProviderInterface, PasswordUpgraderInterface
{
    public function __construct(
        private UserRepository $users,
        private PasswordHasherFactoryInterface $hashers,
        private Transaction $transaction,
        private ClockInterface $clock,
        #[Autowire('%env(int:FLOWCRM_SESSION_ABSOLUTE_LIFETIME)%')]
        private int $absoluteLifetime,
    ) {
    }

    public function loadUserByIdentifier(string $identifier): SecurityUser
    {
        $user = $this->users->ofEmail($identifier);
        if (null === $user) {
            // The same work as for a known address (one Argon2id computation
            // with the configured parameters), so the response time does not
            // tell whether an account exists. The exception names no address.
            $this->hashers->getPasswordHasher(SecurityUser::class)->hash(bin2hex(random_bytes(16)));

            throw new UserNotFoundException();
        }

        return SecurityUser::fromUser($user, $this->clock->now()->getTimestamp());
    }

    /**
     * The current state of the user, with the login time of the session; the
     * session ends (SecurityUser::isEqualTo) when the user is gone or
     * disabled, the credentials changed or the absolute lifetime is over.
     */
    public function refreshUser(UserInterface $user): SecurityUser
    {
        if (!$user instanceof SecurityUser) {
            throw new UnsupportedUserException();
        }
        $current = $this->users->ofId($user->id()) ?? throw new UserNotFoundException();
        $expired = $this->clock->now()->getTimestamp() - $user->authenticatedAt() >= $this->absoluteLifetime;

        return SecurityUser::fromUser($current, $user->authenticatedAt(), $expired);
    }

    public function supportsClass(string $class): bool
    {
        return SecurityUser::class === $class;
    }

    /** A hash made with older parameters, replaced after a successful login (same password). */
    public function upgradePassword(PasswordAuthenticatedUserInterface $user, string $newHashedPassword): void
    {
        if (!$user instanceof SecurityUser) {
            return;
        }
        $current = $this->users->ofId($user->id());
        if (null === $current) {
            return;
        }
        $this->transaction->run(static fn () => $current->rehashPassword($newHashedPassword));
        $user->rehashed($newHashedPassword, $current->passwordChangedAt());
    }
}
