<?php

declare(strict_types=1);

namespace App\Organizations\Domain;

use Doctrine\DBAL\Types\Types;
use Doctrine\ORM\Mapping as ORM;
use Symfony\Component\Uid\Uuid;

/**
 * A user's membership in an organization, with one role (FCRM-003 section
 * F). The user is referenced by ID only: users belong to the Identity
 * module. A removed membership keeps its row (status REMOVED, removed_at).
 * Rules across memberships, such as the last-admin rule (BR-03), belong to
 * the use cases that change memberships.
 */
#[ORM\Entity]
#[ORM\Table(name: 'memberships')]
#[ORM\UniqueConstraint(name: 'memberships_organization_user_key', columns: ['organization_id', 'user_id'])]
#[ORM\UniqueConstraint(name: 'memberships_organization_id_key', columns: ['organization_id', 'id'])]
#[ORM\Index(name: 'memberships_active_user_idx', columns: ['user_id'], options: ['where' => "(status = 'ACTIVE'::text)"])]
class Membership
{
    #[ORM\Id]
    #[ORM\Column(type: 'uuid')]
    private Uuid $id;

    #[ORM\Column(type: 'uuid')]
    private Uuid $organizationId;

    #[ORM\Column(type: 'uuid')]
    private Uuid $userId;

    #[ORM\Column(type: Types::TEXT, enumType: MembershipRole::class)]
    private MembershipRole $role;

    #[ORM\Column(type: Types::TEXT, enumType: MembershipStatus::class)]
    private MembershipStatus $status = MembershipStatus::Active;

    #[ORM\Column(type: Types::DATETIMETZ_IMMUTABLE)]
    private \DateTimeImmutable $createdAt;

    #[ORM\Column(type: Types::DATETIMETZ_IMMUTABLE, nullable: true)]
    private ?\DateTimeImmutable $removedAt = null;

    public function __construct(Uuid $id, Uuid $organizationId, Uuid $userId, MembershipRole $role, \DateTimeImmutable $createdAt)
    {
        $this->id = $id;
        $this->organizationId = $organizationId;
        $this->userId = $userId;
        $this->role = $role;
        $this->createdAt = $createdAt;
    }

    public function remove(\DateTimeImmutable $at): void
    {
        if (MembershipStatus::Removed === $this->status) {
            throw new \LogicException('The membership is already removed.');
        }
        $this->status = MembershipStatus::Removed;
        $this->removedAt = $at;
    }

    public function id(): Uuid
    {
        return $this->id;
    }

    public function organizationId(): Uuid
    {
        return $this->organizationId;
    }

    public function userId(): Uuid
    {
        return $this->userId;
    }

    public function role(): MembershipRole
    {
        return $this->role;
    }

    public function status(): MembershipStatus
    {
        return $this->status;
    }

    public function createdAt(): \DateTimeImmutable
    {
        return $this->createdAt;
    }

    public function removedAt(): ?\DateTimeImmutable
    {
        return $this->removedAt;
    }
}
