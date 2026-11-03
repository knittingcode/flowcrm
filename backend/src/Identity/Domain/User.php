<?php

declare(strict_types=1);

namespace App\Identity\Domain;

use Doctrine\DBAL\Types\Types;
use Doctrine\ORM\Mapping as ORM;
use Symfony\Component\Uid\Uuid;

/**
 * A person who can sign in (FCRM-003 section F). E-mail addresses are
 * unique regardless of case: the database enforces UNIQUE (lower(email)).
 * The password hash comes from the configured password hasher (Argon2id,
 * ADR-019); a user is global, not part of an organization, so only the
 * user or the platform operator changes these attributes.
 */
#[ORM\Entity]
#[ORM\Table(name: 'users')]
class User
{
    public const MAX_EMAIL_LENGTH = 254;

    #[ORM\Id]
    #[ORM\Column(type: 'uuid')]
    private Uuid $id;

    #[ORM\Column(type: Types::TEXT)]
    private string $email;

    #[ORM\Column(type: Types::TEXT)]
    private string $passwordHash;

    #[ORM\Column(type: Types::TEXT)]
    private string $displayName;

    #[ORM\Column(type: Types::DATETIMETZ_IMMUTABLE, nullable: true)]
    private ?\DateTimeImmutable $disabledAt = null;

    #[ORM\Column(type: Types::DATETIMETZ_IMMUTABLE, nullable: true)]
    private ?\DateTimeImmutable $passwordChangedAt = null;

    #[ORM\Column(type: Types::DATETIMETZ_IMMUTABLE)]
    private \DateTimeImmutable $createdAt;

    public function __construct(Uuid $id, string $email, string $passwordHash, string $displayName, \DateTimeImmutable $createdAt)
    {
        if (!self::canHoldEmail($email) || '' === $email || mb_strlen($email) > self::MAX_EMAIL_LENGTH || 1 !== preg_match('/^[^@\s]+@[^@\s]+$/', $email)) {
            throw new \InvalidArgumentException('Invalid e-mail address.');
        }
        if ('' === $passwordHash) {
            throw new \InvalidArgumentException('The password hash is empty.');
        }
        if ('' === trim($displayName)) {
            throw new \InvalidArgumentException('The display name is empty.');
        }

        $this->id = $id;
        $this->email = $email;
        $this->passwordHash = $passwordHash;
        $this->displayName = $displayName;
        $this->createdAt = $createdAt;
    }

    /**
     * Whether a string can be an e-mail address of a user at all: UTF-8
     * without a NUL byte. Lookups treat any other string as matching no user
     * and never send it to PostgreSQL, whose driver (pdo_pgsql) cuts a bound
     * string at its first NUL byte and would match another address (ADR-019).
     */
    public static function canHoldEmail(string $email): bool
    {
        return !str_contains($email, "\0") && mb_check_encoding($email, 'UTF-8');
    }

    /**
     * A new password: every other session of the user ends on its next
     * request, because the credentials changed (ADR-019).
     */
    public function changePassword(string $passwordHash, \DateTimeImmutable $at): void
    {
        if ('' === $passwordHash) {
            throw new \InvalidArgumentException('The password hash is empty.');
        }
        $this->passwordHash = $passwordHash;
        $this->passwordChangedAt = $at;
    }

    /** The same password hashed with the current parameters; not a password change. */
    public function rehashPassword(string $passwordHash): void
    {
        if ('' === $passwordHash) {
            throw new \InvalidArgumentException('The password hash is empty.');
        }
        $this->passwordHash = $passwordHash;
    }

    public function disable(\DateTimeImmutable $at): void
    {
        if (null !== $this->disabledAt) {
            throw new \LogicException('The user is already disabled.');
        }
        $this->disabledAt = $at;
    }

    public function enable(): void
    {
        if (null === $this->disabledAt) {
            throw new \LogicException('The user is not disabled.');
        }
        $this->disabledAt = null;
    }

    public function isDisabled(): bool
    {
        return null !== $this->disabledAt;
    }

    public function id(): Uuid
    {
        return $this->id;
    }

    public function email(): string
    {
        return $this->email;
    }

    public function passwordHash(): string
    {
        return $this->passwordHash;
    }

    public function displayName(): string
    {
        return $this->displayName;
    }

    public function disabledAt(): ?\DateTimeImmutable
    {
        return $this->disabledAt;
    }

    public function passwordChangedAt(): ?\DateTimeImmutable
    {
        return $this->passwordChangedAt;
    }

    public function createdAt(): \DateTimeImmutable
    {
        return $this->createdAt;
    }
}
