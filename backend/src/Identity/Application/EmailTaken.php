<?php

declare(strict_types=1);

namespace App\Identity\Application;

final class EmailTaken extends \DomainException
{
    public function __construct()
    {
        parent::__construct('A user with this e-mail address already exists.');
    }
}
