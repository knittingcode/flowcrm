<?php

declare(strict_types=1);

namespace App\Shared\Infrastructure\Persistence;

use Doctrine\DBAL\Types\Types;
use Doctrine\ORM\Mapping as ORM;

/**
 * Records which schema baseline the database was created from. It holds a
 * single row and no business data; the core schema is created by later
 * migrations (docs/architecture/data-model.md).
 */
#[ORM\Entity(readOnly: true)]
#[ORM\Table(name: 'schema_baseline')]
class SchemaBaseline
{
    #[ORM\Id]
    #[ORM\Column(type: Types::SMALLINT)]
    private int $id;

    #[ORM\Column(type: Types::STRING, length: 64)]
    private string $baseline;

    #[ORM\Column(type: Types::DATETIMETZ_IMMUTABLE)]
    private \DateTimeImmutable $createdAt;

    public function __construct(int $id, string $baseline, \DateTimeImmutable $createdAt)
    {
        $this->id = $id;
        $this->baseline = $baseline;
        $this->createdAt = $createdAt;
    }

    public function id(): int
    {
        return $this->id;
    }

    public function baseline(): string
    {
        return $this->baseline;
    }

    public function createdAt(): \DateTimeImmutable
    {
        return $this->createdAt;
    }
}
