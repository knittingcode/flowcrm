<?php

declare(strict_types=1);

namespace App\Identity\Domain;

use Doctrine\DBAL\Types\Types;
use Doctrine\ORM\Mapping as ORM;
use Symfony\Component\Uid\Uuid;

/**
 * A person who can sign in (FCRM-003 section F). E-mail addresses are
 * unique regardless of case: the database enforces UNIQUE (lower(email)).
 * Authentication is not implemented yet (FND-008); the password hash is
 * produced by the password hasher there.
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
        if ('' === $email || mb_strlen($email) > self::MAX_EMAIL_LENGTH || 1 !== preg_match('/^[^@\s]+@[^@\s]+$/', $email)) {
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
