<?php

declare(strict_types=1);

namespace App\Tests\Support;

use PHPUnit\Framework\Assert;

/**
 * Narrows the mixed values DBAL returns, failing the test on a wrong type
 * instead of casting it away.
 */
trait TypedValues
{
    private static function int(mixed $value): int
    {
        Assert::assertIsInt($value);

        return $value;
    }

    private static function string(mixed $value): string
    {
        if (\is_resource($value)) {
            $value = stream_get_contents($value);
        }
        Assert::assertIsString($value);

        return $value;
    }
}
