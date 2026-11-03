<?php

declare(strict_types=1);

namespace App\Organizations\Infrastructure\Persistence;

use App\Organizations\Domain\Organization;
use App\Organizations\Domain\OrganizationRepository;
use Doctrine\ORM\EntityManagerInterface;
use Symfony\Component\Uid\Uuid;

final readonly class DoctrineOrganizationRepository implements OrganizationRepository
{
    public function __construct(private EntityManagerInterface $entityManager)
    {
    }

    /** Inserted at once (within the caller's transaction): there are no ORM associations to order the inserts by foreign keys. */
    public function add(Organization $organization): void
    {
        $this->entityManager->persist($organization);
        $this->entityManager->flush();
    }

    public function ofId(Uuid $id): ?Organization
    {
        return $this->entityManager->find(Organization::class, $id);
    }
}
