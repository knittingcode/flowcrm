<?php

declare(strict_types=1);

namespace App\Identity\Application;

final class UserNotFound extends \DomainException
{
    public function __construct()
    {
        parent::__construct('No user with this e-mail address exists.');
    }
}
