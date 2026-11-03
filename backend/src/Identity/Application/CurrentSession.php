<?php

declare(strict_types=1);

namespace App\Identity\Application;

interface CurrentSession
{
    /** When the session ends at the latest (absolute lifetime from the login); null when not logged in. */
    public function expiresAt(): ?\DateTimeImmutable;

    /**
     * The current user's credentials changed: the session gets a new ID and
     * stays logged in; every other session of the user ends on its next
     * request.
     */
    public function credentialsChanged(): void;
}
