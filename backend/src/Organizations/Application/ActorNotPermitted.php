<?php

declare(strict_types=1);

namespace App\Organizations\Application;

use App\Organizations\Domain\Permission;

/** Under the organization lock the actor's role (no longer) grants the permission. */
final class ActorNotPermitted extends \DomainException
{
    public function __construct(public readonly Permission $permission, public readonly string $role)
    {
        parent::__construct(\sprintf('The role %s does not grant %s.', $role, $permission->value));
    }
}
