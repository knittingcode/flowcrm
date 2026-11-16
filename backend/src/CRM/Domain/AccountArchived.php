<?php

declare(strict_types=1);

namespace App\CRM\Domain;

/** An archived account cannot be changed. */
final class AccountArchived extends \DomainException
{
    public function __construct()
    {
        parent::__construct('The account is archived.');
    }
}
