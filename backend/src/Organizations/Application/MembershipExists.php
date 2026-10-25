<?php

declare(strict_types=1);

namespace App\Organizations\Application;

/** The user already has a membership in the organization, active or removed (FCRM-002 BR-02; no reactivation). */
final class MembershipExists extends \DomainException
{
    public function __construct()
    {
        parent::__construct('The user already has a membership in this organization (also a removed one).');
    }
}
