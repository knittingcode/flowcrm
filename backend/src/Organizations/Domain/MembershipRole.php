<?php

declare(strict_types=1);

namespace App\Organizations\Domain;

enum MembershipRole: string
{
    case Admin = 'ADMIN';
    case Manager = 'MANAGER';
    case Rep = 'REP';
}
