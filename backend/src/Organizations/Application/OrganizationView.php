<?php

declare(strict_types=1);

namespace App\Organizations\Application;

use Symfony\Component\Uid\Uuid;

final readonly class OrganizationView
{
    public function __construct(
        public Uuid $id,
        public string $name,
        public string $currency,
        public string $timezone,
    ) {
    }
}
