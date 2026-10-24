<?php

declare(strict_types=1);

namespace App\Organizations\Application;

/** The change would leave the organization without an active ADMIN (FCRM-002 BR-03, LastAdminRule). */
final class LastAdmin extends \DomainException
{
    public function __construct()
    {
        parent::__construct('The organization must keep at least one active ADMIN.');
    }
}
