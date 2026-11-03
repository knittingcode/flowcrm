<?php

declare(strict_types=1);

namespace App\Audit\Infrastructure\Persistence;

use App\Audit\Api\AuditRecord;
use App\Audit\Api\AuditTrail;
use App\Audit\Domain\ActorType;
use App\Audit\Domain\AuditEvent;
use Doctrine\ORM\EntityManagerInterface;
use Psr\Clock\ClockInterface;
use Symfony\Component\Uid\Uuid;

final readonly class DoctrineAuditTrail implements AuditTrail
{
    public function __construct(
        private EntityManagerInterface $entityManager,
        private ClockInterface $clock,
    ) {
    }

    public function record(AuditRecord $record): void
    {
        $this->entityManager->persist(new AuditEvent(
            Uuid::v7(),
            $record->organizationId,
            $this->clock->now(),
            ActorType::from($record->actor->type),
            $record->actor->userId,
            $record->actor->role,
            $record->action,
            $record->entityType,
            $record->entityId,
            $record->changes,
            $record->requestId,
            // Raw IP addresses are not written into the immutable log (ADR-019).
            null,
        ));
        $this->entityManager->flush();
    }
}
