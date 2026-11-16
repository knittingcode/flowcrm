<?php

declare(strict_types=1);

namespace App\CRM\Domain;

use Doctrine\DBAL\Types\Types;
use Doctrine\ORM\Mapping as ORM;
use Symfony\Component\Uid\Uuid;

/**
 * A customer company of an organization. Accounts are never deleted: an
 * archived account keeps its data, is left out of the list and can no longer
 * be changed. Tenant table: UNIQUE (organization_id, id), so later tables
 * (contacts, opportunities) can reference an account of the same
 * organization only.
 */
#[ORM\Entity]
#[ORM\Table(name: 'accounts')]
#[ORM\UniqueConstraint(name: 'accounts_organization_id_key', columns: ['organization_id', 'id'])]
class Account
{
    #[ORM\Id]
    #[ORM\Column(type: 'uuid')]
    private Uuid $id;

    #[ORM\Column(type: 'uuid')]
    private Uuid $organizationId;

    #[ORM\Column(type: Types::TEXT)]
    private string $name;

    #[ORM\Column(type: Types::TEXT, nullable: true)]
    private ?string $website;

    #[ORM\Column(type: Types::TEXT, nullable: true)]
    private ?string $email;

    #[ORM\Column(type: Types::TEXT, nullable: true)]
    private ?string $phone;

    #[ORM\Column(type: Types::DATETIMETZ_IMMUTABLE)]
    private \DateTimeImmutable $createdAt;

    #[ORM\Column(type: Types::DATETIMETZ_IMMUTABLE)]
    private \DateTimeImmutable $updatedAt;

    #[ORM\Column(type: Types::DATETIMETZ_IMMUTABLE, nullable: true)]
    private ?\DateTimeImmutable $archivedAt = null;

    public function __construct(Uuid $id, Uuid $organizationId, AccountDetails $details, \DateTimeImmutable $createdAt)
    {
        $this->id = $id;
        $this->organizationId = $organizationId;
        $this->name = $details->name;
        $this->website = $details->website;
        $this->email = $details->email;
        $this->phone = $details->phone;
        $this->createdAt = $createdAt;
        $this->updatedAt = $createdAt;
    }

    /**
     * Replaces the details of an active account.
     *
     * @return list<string> the fields whose value changed
     *
     * @throws AccountArchived
     */
    public function change(AccountDetails $details, \DateTimeImmutable $at): array
    {
        if (null !== $this->archivedAt) {
            throw new AccountArchived();
        }
        $changed = array_keys(array_filter([
            'name' => $this->name !== $details->name,
            'website' => $this->website !== $details->website,
            'email' => $this->email !== $details->email,
            'phone' => $this->phone !== $details->phone,
        ]));
        if ([] === $changed) {
            return [];
        }
        $this->name = $details->name;
        $this->website = $details->website;
        $this->email = $details->email;
        $this->phone = $details->phone;
        $this->updatedAt = $at;

        return $changed;
    }

    /** Archives the account; false when it already was. */
    public function archive(\DateTimeImmutable $at): bool
    {
        if (null !== $this->archivedAt) {
            return false;
        }
        $this->archivedAt = $at;
        $this->updatedAt = $at;

        return true;
    }

    public function id(): Uuid
    {
        return $this->id;
    }

    public function organizationId(): Uuid
    {
        return $this->organizationId;
    }

    public function name(): string
    {
        return $this->name;
    }

    public function website(): ?string
    {
        return $this->website;
    }

    public function email(): ?string
    {
        return $this->email;
    }

    public function phone(): ?string
    {
        return $this->phone;
    }

    public function createdAt(): \DateTimeImmutable
    {
        return $this->createdAt;
    }

    public function updatedAt(): \DateTimeImmutable
    {
        return $this->updatedAt;
    }

    public function archivedAt(): ?\DateTimeImmutable
    {
        return $this->archivedAt;
    }
}
