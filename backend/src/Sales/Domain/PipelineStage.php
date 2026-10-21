<?php

declare(strict_types=1);

namespace App\Sales\Domain;

use Doctrine\DBAL\Types\Types;
use Doctrine\ORM\Mapping as ORM;
use Symfony\Component\Uid\Uuid;

/**
 * A stage of a pipeline (FCRM-003 section F). The database enforces that a
 * stage belongs to a pipeline of the same organization, that active stage
 * names are unique per pipeline regardless of case, and that positions are
 * unique per pipeline (checked at commit, so stages can be reordered in one
 * transaction). The reorder and archive rules (BR-15) belong to the use
 * cases.
 */
#[ORM\Entity]
#[ORM\Table(name: 'pipeline_stages')]
#[ORM\UniqueConstraint(name: 'pipeline_stages_organization_id_key', columns: ['organization_id', 'id'])]
#[ORM\UniqueConstraint(name: 'pipeline_stages_pipeline_position_key', columns: ['pipeline_id', 'position'])]
#[ORM\Index(name: 'pipeline_stages_organization_pipeline_idx', columns: ['organization_id', 'pipeline_id'])]
class PipelineStage
{
    #[ORM\Id]
    #[ORM\Column(type: 'uuid')]
    private Uuid $id;

    #[ORM\Column(type: 'uuid')]
    private Uuid $organizationId;

    #[ORM\Column(type: 'uuid')]
    private Uuid $pipelineId;

    #[ORM\Column(type: Types::TEXT)]
    private string $name;

    #[ORM\Column(type: Types::INTEGER)]
    private int $position;

    #[ORM\Column(type: Types::DATETIMETZ_IMMUTABLE, nullable: true)]
    private ?\DateTimeImmutable $archivedAt = null;

    public function __construct(Uuid $id, Uuid $organizationId, Uuid $pipelineId, string $name, int $position)
    {
        if ('' === trim($name)) {
            throw new \InvalidArgumentException('The stage name is empty.');
        }

        $this->id = $id;
        $this->organizationId = $organizationId;
        $this->pipelineId = $pipelineId;
        $this->name = $name;
        $this->position = $position;
    }

    public function archive(\DateTimeImmutable $at): void
    {
        if (null !== $this->archivedAt) {
            throw new \LogicException('The stage is already archived.');
        }
        $this->archivedAt = $at;
    }

    public function id(): Uuid
    {
        return $this->id;
    }

    public function organizationId(): Uuid
    {
        return $this->organizationId;
    }

    public function pipelineId(): Uuid
    {
        return $this->pipelineId;
    }

    public function name(): string
    {
        return $this->name;
    }

    public function position(): int
    {
        return $this->position;
    }

    public function archivedAt(): ?\DateTimeImmutable
    {
        return $this->archivedAt;
    }
}
