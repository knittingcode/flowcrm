<?php

declare(strict_types=1);

namespace App\Organizations\Application;

/** No user account has this e-mail address (FCRM-002 BR-02: only existing users are added). */
final class UnknownUser extends \DomainException
{
    public function __construct()
    {
        parent::__construct('No user with this e-mail address exists.');
    }
}
