<?php

declare(strict_types=1);

namespace App\Shared\Infrastructure\Persistence;

use App\Shared\Application\Transaction;
use Doctrine\ORM\EntityManagerInterface;

/** One transaction of the default connection; the entity manager is flushed before the commit. */
final readonly class DoctrineTransaction implements Transaction
{
    public function __construct(private EntityManagerInterface $entityManager)
    {
    }

    public function run(callable $work): mixed
    {
        return $this->entityManager->wrapInTransaction(static fn (): mixed => $work());
    }
}
