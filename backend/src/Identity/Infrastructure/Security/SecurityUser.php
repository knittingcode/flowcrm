<?php

declare(strict_types=1);

namespace App\Identity\Infrastructure\Security;

use App\Identity\Domain\User;
use Symfony\Component\Security\Core\User\EquatableInterface;
use Symfony\Component\Security\Core\User\PasswordAuthenticatedUserInterface;
use Symfony\Component\Security\Core\User\UserInterface;
use Symfony\Component\Uid\Uuid;

/**
 * The firewall's view of a user (an adapter, so the domain User stays free
 * of framework code). It is serialized into the session with the security
 * token, without the password hash: only a fingerprint of the credentials
 * (crc32c of the hash, Symfony's supported mechanism, and the time of the
 * last password change) and the login time.
 *
 * On every request the firewall reloads the user (UserProvider::refreshUser)
 * and keeps the session only while isEqualTo() holds: same user, not
 * disabled, same credentials, and within the absolute session lifetime.
 * Otherwise the token is dropped and SessionEndListener ends the session.
 *
 * Every user has ROLE_USER only: organization roles are per membership and
 * decided per request (ADR-019), never global Symfony roles.
 */
final class SecurityUser implements UserInterface, PasswordAuthenticatedUserInterface, EquatableInterface
{
    private function __construct(
        private readonly string $id,
        private ?string $passwordHash,
        private string $credentials,
        private readonly bool $disabled,
        private readonly int $authenticatedAt,
        private readonly bool $expired,
    ) {
    }

    /**
     * @param int  $authenticatedAt Unix time of the login this session belongs to
     * @param bool $expired         the absolute session lifetime is over
     */
    public static function fromUser(User $user, int $authenticatedAt, bool $expired = false): self
    {
        return new self($user->id()->toRfc4122(), $user->passwordHash(), self::fingerprint($user->passwordHash(), $user->passwordChangedAt()), $user->isDisabled(), $authenticatedAt, $expired);
    }

    public function id(): Uuid
    {
        return Uuid::fromString($this->id);
    }

    public function authenticatedAt(): int
    {
        return $this->authenticatedAt;
    }

    public function isDisabled(): bool
    {
        return $this->disabled;
    }

    /**
     * The same password was rehashed with the current parameters during the
     * login; the session that logged in stays valid.
     */
    public function rehashed(string $passwordHash, ?\DateTimeImmutable $passwordChangedAt): void
    {
        $this->passwordHash = $passwordHash;
        $this->credentials = self::fingerprint($passwordHash, $passwordChangedAt);
    }

    public function getRoles(): array
    {
        return ['ROLE_USER'];
    }

    /** The hash only while the user was loaded from the database (login); null after unserialize. */
    public function getPassword(): ?string
    {
        return $this->passwordHash;
    }

    /** @return non-empty-string the user ID: stable across e-mail changes */
    public function getUserIdentifier(): string
    {
        return '' !== $this->id ? $this->id : throw new \LogicException('A user has an ID.');
    }

    #[\Deprecated]
    public function eraseCredentials(): void
    {
    }

    public function isEqualTo(UserInterface $user): bool
    {
        return $user instanceof self
            && $user->id === $this->id
            && !$user->disabled
            && !$user->expired
            && hash_equals($this->credentials, $user->credentials);
    }

    /** @return array{id: string, credentials: string, authenticatedAt: int} */
    public function __serialize(): array
    {
        return ['id' => $this->id, 'credentials' => $this->credentials, 'authenticatedAt' => $this->authenticatedAt];
    }

    /** @param array{id: string, credentials: string, authenticatedAt: int} $data */
    public function __unserialize(array $data): void
    {
        $this->id = $data['id'];
        $this->credentials = $data['credentials'];
        $this->authenticatedAt = $data['authenticatedAt'];
        $this->passwordHash = null;
        $this->disabled = false;
        $this->expired = false;
    }

    private static function fingerprint(string $passwordHash, ?\DateTimeImmutable $passwordChangedAt): string
    {
        return hash('crc32c', $passwordHash).':'.($passwordChangedAt?->format('U') ?? '-');
    }
}
