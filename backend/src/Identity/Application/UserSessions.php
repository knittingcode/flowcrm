<?php

declare(strict_types=1);

namespace App\Identity\Application;

use Symfony\Component\Uid\Uuid;

interface UserSessions
{
    /**
     * Ends every stored session of the user at once, in the caller's
     * transaction: a session ended this way cannot come back, not even when
     * the reason for ending it (a disabled account) is undone.
     */
    public function endAll(Uuid $userId): void;
}
