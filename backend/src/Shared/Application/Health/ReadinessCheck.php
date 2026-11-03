<?php

declare(strict_types=1);

namespace App\Shared\Application\Health;

/**
 * Whether the application can serve requests that need its dependencies.
 */
interface ReadinessCheck
{
    /**
     * @throws \Throwable when a dependency cannot be reached
     */
    public function check(): ReadinessResult;
}
