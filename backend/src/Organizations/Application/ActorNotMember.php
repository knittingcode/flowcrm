<?php

declare(strict_types=1);

namespace App\Organizations\Application;

/** Under the organization lock the actor has no active membership (any more), or the organization is gone. */
final class ActorNotMember extends \DomainException
{
    public function __construct()
    {
        parent::__construct('The actor has no active membership in the organization.');
    }
}
