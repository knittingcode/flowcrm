<?php

declare(strict_types=1);

namespace App\Shared\Infrastructure\Database;

interface ReadinessCheck
{
    /**
     * @throws \Throwable when a dependency cannot be reached
     */
    public function check(): ReadinessResult;
}
