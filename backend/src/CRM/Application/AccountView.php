<?php

declare(strict_types=1);

namespace App\CRM\Application;

use Symfony\Component\Uid\Uuid;

/** An account as the API shows it. */
final readonly class AccountView
{
    public function __construct(
        public Uuid $id,
        public string $name,
        public ?string $website,
        public ?string $email,
        public ?string $phone,
        public \DateTimeImmutable $createdAt,
        public \DateTimeImmutable $updatedAt,
        public ?\DateTimeImmutable $archivedAt,
    ) {
    }
}
