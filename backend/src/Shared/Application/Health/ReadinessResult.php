<?php

declare(strict_types=1);

namespace App\Shared\Application\Health;

final readonly class ReadinessResult
{
    private function __construct(
        public bool $ready,
        public ?string $reason,
    ) {
    }

    public static function ready(): self
    {
        return new self(true, null);
    }

    /**
     * @param string $reason internal diagnostic; logged, never returned to clients
     */
    public static function notReady(string $reason): self
    {
        return new self(false, $reason);
    }
}
