<?php

declare(strict_types=1);

namespace App\Identity\Infrastructure\Persistence;

use App\Identity\Domain\User;
use App\Identity\Domain\UserRepository;
use Doctrine\ORM\EntityManagerInterface;
use Symfony\Component\Uid\Uuid;

final readonly class DoctrineUserRepository implements UserRepository
{
    public function __construct(private EntityManagerInterface $entityManager)
    {
    }

    public function ofId(Uuid $id): ?User
    {
        return $this->entityManager->find(User::class, $id);
    }

    public function ofEmail(string $email): ?User
    {
        $user = $this->entityManager
            ->createQuery('SELECT u FROM '.User::class.' u WHERE LOWER(u.email) = LOWER(:email)')
            ->setParameter('email', $email)
            ->getOneOrNullResult();

        return $user instanceof User ? $user : null;
    }

    /** Inserted at once (within the caller's transaction): there are no ORM associations to order the inserts by foreign keys. */
    public function add(User $user): void
    {
        $this->entityManager->persist($user);
        $this->entityManager->flush();
    }
}
