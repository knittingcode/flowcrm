<?php

declare(strict_types=1);

namespace App\Identity\Api;

use Symfony\Component\Uid\Uuid;

/** The user of the current request, as authenticated by the firewall. */
interface CurrentUser
{
    /** Null for anonymous requests. Reading it loads the session when the request has one. */
    public function id(): ?Uuid;
}
