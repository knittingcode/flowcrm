<?php

declare(strict_types=1);

namespace App\Shared\Infrastructure\Persistence;

use Doctrine\DBAL\Platforms\AbstractPlatform;
use Doctrine\DBAL\Types\Type;

/**
 * PostgreSQL inet (an IP address), as a string in PHP. Registered as the
 * DBAL type "inet" and as the mapping of the database type inet, so schema
 * comparison recognises the column.
 */
final class InetType extends Type
{
    public const NAME = 'inet';

    public function getSQLDeclaration(array $column, AbstractPlatform $platform): string
    {
        return 'INET';
    }

    public function convertToPHPValue(mixed $value, AbstractPlatform $platform): ?string
    {
        return null === $value ? null : (\is_scalar($value) ? (string) $value : throw new \UnexpectedValueException('Unexpected inet value.'));
    }
}
