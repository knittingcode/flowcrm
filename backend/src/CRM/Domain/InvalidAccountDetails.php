<?php

declare(strict_types=1);

namespace App\CRM\Domain;

/** Account details that break a rule; one stable code per field. */
final class InvalidAccountDetails extends \DomainException
{
    /** @param non-empty-array<string, string> $violations field => code */
    public function __construct(public readonly array $violations)
    {
        parent::__construct('Invalid account details.');
    }
}
