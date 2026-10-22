<?php

declare(strict_types=1);

namespace App\Shared\Infrastructure\Cache;

/**
 * A schema change on the cache connection (RejectSchemaChanges).
 */
final class SchemaChangeRejected extends \RuntimeException
{
}
