<?php

declare(strict_types=1);

namespace App\Organizations\Domain;

use Symfony\Component\Uid\Uuid;

interface OrganizationRepository
{
    public function add(Organization $organization): void;

    public function ofId(Uuid $id): ?Organization;
}
