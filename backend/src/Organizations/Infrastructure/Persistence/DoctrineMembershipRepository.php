<?php

declare(strict_types=1);

namespace App\Organizations\Infrastructure\Persistence;

use App\Organizations\Domain\Membership;
use App\Organizations\Domain\MembershipRepository;
use Doctrine\ORM\EntityManagerInterface;
use Symfony\Component\Uid\Uuid;

final readonly class DoctrineMembershipRepository implements MembershipRepository
{
    public function __construct(private EntityManagerInterface $entityManager)
    {
    }

    /** Inserted at once (within the caller's transaction): there are no ORM associations to order the inserts by foreign keys. */
    public function add(Membership $membership): void
    {
        $this->entityManager->persist($membership);
        $this->entityManager->flush();
    }

    public function ofOrganizationAndUser(Uuid $organizationId, Uuid $userId): ?Membership
    {
        return $this->entityManager->getRepository(Membership::class)->findOneBy(['organizationId' => $organizationId, 'userId' => $userId]);
    }

    public function ofOrganizationAndId(Uuid $organizationId, Uuid $membershipId): ?Membership
    {
        return $this->entityManager->getRepository(Membership::class)->findOneBy(['organizationId' => $organizationId, 'id' => $membershipId]);
    }

    public function activeAdminCount(Uuid $organizationId): int
    {
        $count = $this->entityManager->getConnection()->fetchOne(
            "SELECT count(*) FROM memberships WHERE organization_id = ? AND role = 'ADMIN' AND status = 'ACTIVE'",
            [$organizationId->toRfc4122()],
        );

        return is_numeric($count) ? (int) $count : throw new \UnexpectedValueException('Unexpected count of administrators.');
    }
}
