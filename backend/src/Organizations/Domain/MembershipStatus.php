<?php

declare(strict_types=1);

namespace App\Organizations\Domain;

enum MembershipStatus: string
{
    case Active = 'ACTIVE';
    case Removed = 'REMOVED';
}
