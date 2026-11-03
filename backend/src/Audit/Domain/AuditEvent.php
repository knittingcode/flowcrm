<?php

declare(strict_types=1);

namespace App\Audit\Domain;

use Doctrine\DBAL\Types\Types;
use Doctrine\ORM\Mapping as ORM;
use Symfony\Component\Uid\Uuid;

/**
 * One entry of the append-only audit log (FCRM-003 section F). Rows are
 * never changed: a database trigger rejects UPDATE, DELETE and TRUNCATE.
 * The organization is null for platform-wide events.
 */
#[ORM\Entity(readOnly: true)]
#[ORM\Table(name: 'audit_events')]
#[ORM\Index(name: 'audit_events_organization_time_idx', columns: ['organization_id', 'occurred_at', 'id'])]
#[ORM\Index(name: 'audit_events_organization_entity_idx', columns: ['organization_id', 'entity_type', 'entity_id', 'occurred_at'])]
class AuditEvent
{
    #[ORM\Id]
    #[ORM\Column(type: 'uuid')]
    private Uuid $id;

    #[ORM\Column(type: 'uuid', nullable: true)]
    private ?Uuid $organizationId;

    #[ORM\Column(type: Types::DATETIMETZ_IMMUTABLE)]
    private \DateTimeImmutable $occurredAt;

    #[ORM\Column(type: Types::TEXT, enumType: ActorType::class)]
    private ActorType $actorType;

    #[ORM\Column(type: 'uuid', nullable: true)]
    private ?Uuid $actorUserId;

    #[ORM\Column(type: Types::TEXT, nullable: true)]
    private ?string $actorRole;

    #[ORM\Column(type: Types::TEXT)]
    private string $action;

    #[ORM\Column(type: Types::TEXT)]
    private string $entityType;

    #[ORM\Column(type: 'uuid', nullable: true)]
    private ?Uuid $entityId;

    /** @var array<string, mixed> */
    #[ORM\Column(type: Types::JSON, options: ['jsonb' => true])]
    private array $changes;

    #[ORM\Column(type: 'uuid', nullable: true)]
    private ?Uuid $requestId;

    #[ORM\Column(type: 'inet', nullable: true)]
    private ?string $ip;

    /**
     * @param array<string, mixed> $changes
     */
    public function __construct(
        Uuid $id,
        ?Uuid $organizationId,
        \DateTimeImmutable $occurredAt,
        ActorType $actorType,
        ?Uuid $actorUserId,
        ?string $actorRole,
        string $action,
        string $entityType,
        ?Uuid $entityId,
        array $changes,
        ?Uuid $requestId,
        ?string $ip,
    ) {
        if ('' === $action || '' === $entityType) {
            throw new \InvalidArgumentException('An audit event needs an action and an entity type.');
        }
        if (null !== $ip && false === filter_var($ip, \FILTER_VALIDATE_IP)) {
            throw new \InvalidArgumentException('Invalid IP address.');
        }

        $this->id = $id;
        $this->organizationId = $organizationId;
        $this->occurredAt = $occurredAt;
        $this->actorType = $actorType;
        $this->actorUserId = $actorUserId;
        $this->actorRole = $actorRole;
        $this->action = $action;
        $this->entityType = $entityType;
        $this->entityId = $entityId;
        $this->changes = $changes;
        $this->requestId = $requestId;
        $this->ip = $ip;
    }

    public function id(): Uuid
    {
        return $this->id;
    }

    public function organizationId(): ?Uuid
    {
        return $this->organizationId;
    }

    public function occurredAt(): \DateTimeImmutable
    {
        return $this->occurredAt;
    }

    public function actorType(): ActorType
    {
        return $this->actorType;
    }

    public function actorUserId(): ?Uuid
    {
        return $this->actorUserId;
    }

    public function actorRole(): ?string
    {
        return $this->actorRole;
    }

    public function action(): string
    {
        return $this->action;
    }

    public function entityType(): string
    {
        return $this->entityType;
    }

    public function entityId(): ?Uuid
    {
        return $this->entityId;
    }

    /**
     * @return array<string, mixed>
     */
    public function changes(): array
    {
        return $this->changes;
    }

    public function requestId(): ?Uuid
    {
        return $this->requestId;
    }

    public function ip(): ?string
    {
        return $this->ip;
    }
}
