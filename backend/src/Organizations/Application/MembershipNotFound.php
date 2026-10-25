<?php

declare(strict_types=1);

namespace App\Organizations\Application;

/** The target membership is unknown, of another organization or removed (one answer for all three). */
final class MembershipNotFound extends \DomainException
{
    public function __construct()
    {
        parent::__construct('No active membership with this ID exists in the organization.');
    }
}
