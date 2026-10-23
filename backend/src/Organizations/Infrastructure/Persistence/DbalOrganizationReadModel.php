<?php

declare(strict_types=1);

namespace App\Organizations\Infrastructure\Persistence;

use App\Organizations\Api\MembershipDirectory;
use App\Organizations\Api\MembershipSummary;
use App\Organizations\Api\TenantContext;
use App\Organizations\Application\MemberRow;
use App\Organizations\Application\OrganizationReadModel;
use App\Organizations\Application\OrganizationView;
use App\Organizations\Domain\MembershipRole;
use App\Organizations\Domain\Permission;
use App\Organizations\Domain\RolePolicy;
use Doctrine\DBAL\Connection;
use Symfony\Component\Uid\Uuid;

/**
 * Plain SQL reads of the organization module. Each query is filtered by
 * the organization (or, for the user's own memberships, by the user) and by
 * status = 'ACTIVE'; memberships are looked up on every request, never cached.
 */
final readonly class DbalOrganizationReadModel implements OrganizationReadModel, MembershipDirectory
{
    public function __construct(private Connection $connection)
    {
    }

    public function activeMembership(Uuid $organizationId, Uuid $userId): ?TenantContext
    {
        $row = $this->connection->fetchAssociative(
            "SELECT id, role FROM memberships WHERE organization_id = ? AND user_id = ? AND status = 'ACTIVE'",
            [$organizationId->toRfc4122(), $userId->toRfc4122()],
        );
        if (false === $row) {
            return null;
        }

        return new TenantContext($organizationId, Uuid::fromString(self::text($row, 'id')), $userId, MembershipRole::from(self::text($row, 'role'))->value);
    }

    public function organization(Uuid $organizationId): ?OrganizationView
    {
        $row = $this->connection->fetchAssociative('SELECT id, name, currency, timezone FROM organizations WHERE id = ?', [$organizationId->toRfc4122()]);
        if (false === $row) {
            return null;
        }

        return new OrganizationView($organizationId, self::text($row, 'name'), self::text($row, 'currency'), self::text($row, 'timezone'));
    }

    public function members(Uuid $organizationId, int $offset, int $limit): array
    {
        $rows = $this->connection->fetchAllAssociative(
            "SELECT id, user_id, role FROM memberships WHERE organization_id = ? AND status = 'ACTIVE' ORDER BY created_at, id LIMIT ? OFFSET ?",
            [$organizationId->toRfc4122(), $limit, $offset],
        );
        $total = $this->connection->fetchOne("SELECT count(*) FROM memberships WHERE organization_id = ? AND status = 'ACTIVE'", [$organizationId->toRfc4122()]);

        return [array_map(self::memberRow(...), $rows), (int) (is_numeric($total) ? $total : 0)];
    }

    public function member(Uuid $organizationId, Uuid $membershipId): ?MemberRow
    {
        $row = $this->connection->fetchAssociative(
            "SELECT id, user_id, role FROM memberships WHERE organization_id = ? AND id = ? AND status = 'ACTIVE'",
            [$organizationId->toRfc4122(), $membershipId->toRfc4122()],
        );

        return false === $row ? null : self::memberRow($row);
    }

    public function activeMembershipsOf(Uuid $userId): array
    {
        $rows = $this->connection->fetchAllAssociative(
            "SELECT m.id, m.organization_id, o.name, m.role FROM memberships m JOIN organizations o ON o.id = m.organization_id WHERE m.user_id = ? AND m.status = 'ACTIVE' ORDER BY o.name, o.id",
            [$userId->toRfc4122()],
        );

        return array_map(static function (array $row): MembershipSummary {
            $role = MembershipRole::from(self::text($row, 'role'));

            return new MembershipSummary(
                Uuid::fromString(self::text($row, 'organization_id')),
                self::text($row, 'name'),
                Uuid::fromString(self::text($row, 'id')),
                $role->value,
                array_map(static fn (Permission $p): string => $p->value, RolePolicy::permissionsOf($role)),
            );
        }, $rows);
    }

    /** @param array<string, mixed> $row */
    private static function memberRow(array $row): MemberRow
    {
        return new MemberRow(Uuid::fromString(self::text($row, 'id')), Uuid::fromString(self::text($row, 'user_id')), self::text($row, 'role'));
    }

    /** @param array<string, mixed> $row */
    private static function text(array $row, string $column): string
    {
        $value = $row[$column] ?? null;

        return \is_string($value) ? $value : throw new \UnexpectedValueException('Unexpected value in column '.$column);
    }
}
