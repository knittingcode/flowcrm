<?php

declare(strict_types=1);

namespace App\Audit\Domain;

enum ActorType: string
{
    case User = 'user';
    case PlatformOperator = 'platform_operator';
    case System = 'system';
}
