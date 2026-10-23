<?php

declare(strict_types=1);

namespace App\Shared\Application;

/**
 * Runs a unit of work atomically: every change, including its audit event,
 * is committed together or not at all.
 */
interface Transaction
{
    /**
     * @template T
     *
     * @param callable(): T $work
     *
     * @return T
     */
    public function run(callable $work): mixed;
}
