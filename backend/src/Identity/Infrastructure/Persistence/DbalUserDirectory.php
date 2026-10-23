<?php

declare(strict_types=1);

namespace App\Identity\Infrastructure\Persistence;

use App\Identity\Api\UserDirectory;
use App\Identity\Api\UserProfile;
use Doctrine\DBAL\ArrayParameterType;
use Doctrine\DBAL\Connection;
use Symfony\Component\Uid\Uuid;

final readonly class DbalUserDirectory implements UserDirectory
{
    public function __construct(private Connection $connection)
    {
    }

    public function profiles(array $ids): array
    {
        if ([] === $ids) {
            return [];
        }
        $rows = $this->connection->fetchAllAssociative(
            'SELECT id, email, display_name FROM users WHERE id IN (?)',
            [array_map(static fn (Uuid $id): string => $id->toRfc4122(), $ids)],
            [ArrayParameterType::STRING],
        );
        $profiles = [];
        foreach ($rows as $row) {
            [$id, $email, $name] = [$row['id'], $row['email'], $row['display_name']];
            if (\is_string($id) && \is_string($email) && \is_string($name)) {
                $profiles[$id] = new UserProfile(Uuid::fromString($id), $email, $name);
            }
        }

        return $profiles;
    }

    public function idOfEmail(string $email): ?Uuid
    {
        $id = $this->connection->fetchOne('SELECT id FROM users WHERE lower(email) = lower(?)', [$email]);

        return \is_string($id) ? Uuid::fromString($id) : null;
    }
}
