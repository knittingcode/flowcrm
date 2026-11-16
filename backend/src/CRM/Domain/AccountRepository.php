<?php

declare(strict_types=1);

namespace App\CRM\Domain;

use Symfony\Component\Uid\Uuid;

interface AccountRepository
{
    public function add(Account $account): void;

    /** The account of this organization; null when the ID belongs to another organization or to none. */
    public function ofId(Uuid $organizationId, Uuid $id): ?Account;
}
