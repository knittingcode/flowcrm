<?php

declare(strict_types=1);

namespace App\CRM\Infrastructure\Persistence;

use App\CRM\Domain\Account;
use App\CRM\Domain\AccountRepository;
use Doctrine\ORM\EntityManagerInterface;
use Symfony\Component\Uid\Uuid;

final readonly class DoctrineAccountRepository implements AccountRepository
{
    public function __construct(private EntityManagerInterface $entityManager)
    {
    }

    /** Inserted at once, within the caller's transaction. */
    public function add(Account $account): void
    {
        $this->entityManager->persist($account);
        $this->entityManager->flush();
    }

    /** Looked up by organization and ID together, never by the ID alone. */
    public function ofId(Uuid $organizationId, Uuid $id): ?Account
    {
        return $this->entityManager->getRepository(Account::class)->findOneBy(['organizationId' => $organizationId, 'id' => $id]);
    }
}
