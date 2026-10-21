<?php

declare(strict_types=1);

namespace App\Shared\Application\SystemStatus;

interface DatabaseTime
{
    /**
     * The current time according to the database, in UTC.
     *
     * @throws \Throwable when the database cannot be reached
     */
    public function databaseTime(): \DateTimeImmutable;
}
