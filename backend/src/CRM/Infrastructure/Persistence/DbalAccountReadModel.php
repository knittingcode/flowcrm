<?php

declare(strict_types=1);

namespace App\CRM\Infrastructure\Persistence;

use App\CRM\Application\AccountReadModel;
use App\CRM\Application\AccountView;
use Doctrine\DBAL\Connection;
use Symfony\Component\Uid\Uuid;

/** Plain SQL reads of accounts; each query is filtered by the organization. */
final readonly class DbalAccountReadModel implements AccountReadModel
{
    private const COLUMNS = 'id, name, website, email, phone, created_at, updated_at, archived_at';

    public function __construct(private Connection $connection)
    {
    }

    public function page(Uuid $organizationId, int $offset, int $limit): array
    {
        $rows = $this->connection->fetchAllAssociative(
            'SELECT '.self::COLUMNS.' FROM accounts WHERE organization_id = ? AND archived_at IS NULL ORDER BY lower(name), id LIMIT ? OFFSET ?',
            [$organizationId->toRfc4122(), $limit, $offset],
        );
        $total = $this->connection->fetchOne('SELECT count(*) FROM accounts WHERE organization_id = ? AND archived_at IS NULL', [$organizationId->toRfc4122()]);

        return [array_map(self::view(...), $rows), (int) (is_numeric($total) ? $total : 0)];
    }

    public function account(Uuid $organizationId, Uuid $accountId): ?AccountView
    {
        $row = $this->connection->fetchAssociative(
            'SELECT '.self::COLUMNS.' FROM accounts WHERE organization_id = ? AND id = ?',
            [$organizationId->toRfc4122(), $accountId->toRfc4122()],
        );

        return false === $row ? null : self::view($row);
    }

    /** @param array<string, mixed> $row */
    private static function view(array $row): AccountView
    {
        return new AccountView(
            Uuid::fromString(self::text($row, 'id')),
            self::text($row, 'name'),
            self::optionalText($row, 'website'),
            self::optionalText($row, 'email'),
            self::optionalText($row, 'phone'),
            new \DateTimeImmutable(self::text($row, 'created_at')),
            new \DateTimeImmutable(self::text($row, 'updated_at')),
            null === ($row['archived_at'] ?? null) ? null : new \DateTimeImmutable(self::text($row, 'archived_at')),
        );
    }

    /** @param array<string, mixed> $row */
    private static function text(array $row, string $column): string
    {
        $value = $row[$column] ?? null;

        return \is_string($value) ? $value : throw new \UnexpectedValueException('Unexpected value in column '.$column);
    }

    /** @param array<string, mixed> $row */
    private static function optionalText(array $row, string $column): ?string
    {
        return null === ($row[$column] ?? null) ? null : self::text($row, $column);
    }
}
