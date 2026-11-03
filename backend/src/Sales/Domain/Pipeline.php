<?php

declare(strict_types=1);

namespace App\Sales\Domain;

use Doctrine\ORM\Mapping as ORM;
use Symfony\Component\Uid\Uuid;

/**
 * The sales pipeline of an organization; each organization has exactly one
 * (FCRM-003 section F).
 */
#[ORM\Entity]
#[ORM\Table(name: 'pipelines')]
#[ORM\UniqueConstraint(name: 'pipelines_organization_key', columns: ['organization_id'])]
#[ORM\UniqueConstraint(name: 'pipelines_organization_id_key', columns: ['organization_id', 'id'])]
class Pipeline
{
    #[ORM\Id]
    #[ORM\Column(type: 'uuid')]
    private Uuid $id;

    #[ORM\Column(type: 'uuid')]
    private Uuid $organizationId;

    public function __construct(Uuid $id, Uuid $organizationId)
    {
        $this->id = $id;
        $this->organizationId = $organizationId;
    }

    public function id(): Uuid
    {
        return $this->id;
    }

    public function organizationId(): Uuid
    {
        return $this->organizationId;
    }
}
