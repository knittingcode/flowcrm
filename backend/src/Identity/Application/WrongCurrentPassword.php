<?php

declare(strict_types=1);

namespace App\Identity\Application;

final class WrongCurrentPassword extends \DomainException
{
    public function __construct()
    {
        parent::__construct('The current password is wrong.');
    }
}
