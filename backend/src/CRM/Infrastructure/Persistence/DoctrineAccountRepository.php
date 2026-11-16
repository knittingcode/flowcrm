<?php

declare(strict_types=1);

namespace App\CRM\Infrastructure\Persistence;

use App\CRM\Domain\Account;
use App\CRM\Domain\AccountRepository;
use Doctrine\DBAL\LockMode;
use Doctrine\ORM\EntityManagerInterface;
use Doctrine\ORM\Query;
use Symfony\Bridge\Doctrine\Types\UuidType;
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

    /**
     * Looked up by organization and ID together, never by the ID alone, and
     * read again from the database with a row lock (SELECT ... FOR UPDATE):
     * two requests that change the same account run one after the other, so
     * the second one sees what the first one committed.
     */
    public function ofId(Uuid $organizationId, Uuid $id): ?Account
    {
        $account = $this->entityManager
            ->createQuery('SELECT a FROM '.Account::class.' a WHERE a.organizationId = :organization AND a.id = :id')
            ->setParameter('organization', $organizationId, UuidType::NAME)
            ->setParameter('id', $id, UuidType::NAME)
            ->setLockMode(LockMode::PESSIMISTIC_WRITE)
            ->setHint(Query::HINT_REFRESH, true)
            ->getOneOrNullResult();

        return $account instanceof Account ? $account : null;
    }
}
