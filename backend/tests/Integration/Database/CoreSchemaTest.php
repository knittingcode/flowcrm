<?php

declare(strict_types=1);

namespace App\Tests\Integration\Database;

use Doctrine\DBAL\Connection;
use Doctrine\DBAL\Exception\DriverException;
use Symfony\Bundle\FrameworkBundle\Test\KernelTestCase;
use Symfony\Component\Uid\Uuid;

/**
 * The invariants of the core schema (FCRM-003 section F), enforced by
 * PostgreSQL itself and tested with raw SQL, so they hold even if
 * application code is wrong. Every test runs in a transaction that is
 * rolled back; each expected violation runs in its own savepoint.
 */
final class CoreSchemaTest extends KernelTestCase
{
    private const UNIQUE = '23505';
    private const FOREIGN_KEY = '23503';
    private const CHECK = '23514';
    private const NOT_ALLOWED = '42501';

    private Connection $db;

    protected function setUp(): void
    {
        $db = self::getContainer()->get('doctrine.dbal.default_connection');
        self::assertInstanceOf(Connection::class, $db);
        $this->db = $db;
        $this->db->beginTransaction();
    }

    protected function tearDown(): void
    {
        $this->db->rollBack();
        parent::tearDown();
    }

    public function testEmailAddressesAreUniqueRegardlessOfCase(): void
    {
        $this->user('Anna@Example.com');

        $this->assertViolation(self::UNIQUE, 'users_email_lower_key', fn () => $this->user('anna@example.COM'));
        $this->user('anna.other@example.com');
    }

    public function testEmailLengthIsLimited(): void
    {
        $this->assertViolation(self::CHECK, 'users_email_length_check', fn () => $this->user(str_repeat('a', 243).'@example.com'));
        $this->user(str_repeat('a', 242).'@example.com');
    }

    public function testOnlyAllowedCurrencies(): void
    {
        $this->assertViolation(self::CHECK, 'organizations_currency_check', fn () => $this->organization('XYZ'));
        $this->organization('PLN');
    }

    public function testAUserIsAMemberOfAnOrganizationOnce(): void
    {
        $org = $this->organization();
        $user = $this->user();
        $this->membership($org, $user);

        $this->assertViolation(self::UNIQUE, 'memberships_organization_user_key', fn () => $this->membership($org, $user, 'REP'));
        $this->membership($this->organization(), $user);
    }

    public function testMembershipRoleAndStatusAreChecked(): void
    {
        $org = $this->organization();

        $this->assertViolation(self::CHECK, 'memberships_role_check', fn () => $this->membership($org, $this->user(), 'OWNER'));
        $this->assertViolation(self::CHECK, 'memberships_status_check', fn () => $this->membership($org, $this->user(), status: 'SUSPENDED'));
        $this->assertViolation(self::CHECK, 'memberships_removed_at_check', fn () => $this->membership($org, $this->user(), status: 'REMOVED'));
        $this->assertViolation(self::CHECK, 'memberships_removed_at_check', fn () => $this->membership($org, $this->user(), removedAt: '2026-10-22T00:00:00Z'));
        $this->membership($org, $this->user(), status: 'REMOVED', removedAt: '2026-10-22T00:00:00Z');
    }

    public function testMembershipsReferenceExistingUsersAndOrganizations(): void
    {
        $this->assertViolation(self::FOREIGN_KEY, 'memberships_user_fkey', fn () => $this->membership($this->organization(), Uuid::v7()->toRfc4122()));
        $this->assertViolation(self::FOREIGN_KEY, 'memberships_organization_fkey', fn () => $this->membership(Uuid::v7()->toRfc4122(), $this->user()));
    }

    public function testAnOrganizationHasOnePipeline(): void
    {
        $org = $this->organization();
        $this->pipeline($org);

        $this->assertViolation(self::UNIQUE, 'pipelines_organization_key', fn () => $this->pipeline($org));
    }

    public function testAStageCannotBelongToThePipelineOfAnotherOrganization(): void
    {
        $orgA = $this->organization();
        $orgB = $this->organization();
        $pipelineB = $this->pipeline($orgB);

        $this->assertViolation(self::FOREIGN_KEY, 'pipeline_stages_pipeline_fkey', fn () => $this->stage($orgA, $pipelineB, 'Qualified', 1));
        $this->stage($orgB, $pipelineB, 'Qualified', 1);
    }

    public function testActiveStageNamesAreUniquePerPipelineRegardlessOfCase(): void
    {
        $org = $this->organization();
        $pipeline = $this->pipeline($org);
        $this->stage($org, $pipeline, 'Proposal', 1, archived: true);
        $this->stage($org, $pipeline, 'Proposal', 2, archived: true);
        $this->stage($org, $pipeline, 'Proposal', 3);

        $this->assertViolation(self::UNIQUE, 'pipeline_stages_active_name_key', fn () => $this->stage($org, $pipeline, 'PROPOSAL', 4));
        $other = $this->organization();
        $this->stage($other, $this->pipeline($other), 'Proposal', 1);
    }

    public function testStagePositionsAreUniquePerPipelineAtCommit(): void
    {
        $org = $this->organization();
        $pipeline = $this->pipeline($org);
        $first = $this->stage($org, $pipeline, 'Lead', 1);
        $second = $this->stage($org, $pipeline, 'Won', 2);

        // Swapping two positions passes: the check is deferred to the commit.
        $this->db->executeStatement('UPDATE pipeline_stages SET position = 2 WHERE id = ?', [$first]);
        $this->db->executeStatement('UPDATE pipeline_stages SET position = 1 WHERE id = ?', [$second]);
        $this->db->executeStatement('SET CONSTRAINTS pipeline_stages_pipeline_position_key IMMEDIATE');
        $this->db->executeStatement('SET CONSTRAINTS pipeline_stages_pipeline_position_key DEFERRED');

        $this->assertViolation(self::UNIQUE, 'pipeline_stages_pipeline_position_key', function () use ($org, $pipeline): void {
            $this->stage($org, $pipeline, 'Lost', 2);
            $this->db->executeStatement('SET CONSTRAINTS pipeline_stages_pipeline_position_key IMMEDIATE');
        });
    }

    public function testTheAuditLogIsAppendOnly(): void
    {
        $id = $this->auditEvent($this->organization());
        $this->auditEvent(null);

        $this->assertViolation(self::NOT_ALLOWED, 'append-only: UPDATE', fn () => $this->db->executeStatement("UPDATE audit_events SET action = 'changed' WHERE id = ?", [$id]));
        $this->assertViolation(self::NOT_ALLOWED, 'append-only: DELETE', fn () => $this->db->executeStatement('DELETE FROM audit_events WHERE id = ?', [$id]));
        $this->assertViolation(self::NOT_ALLOWED, 'append-only: TRUNCATE', fn () => $this->db->executeStatement('TRUNCATE audit_events'));
        self::assertEquals(2, $this->db->fetchOne('SELECT count(*) FROM audit_events'));
    }

    public function testAuditEventsAreChecked(): void
    {
        $this->assertViolation(self::CHECK, 'audit_events_actor_type_check', fn () => $this->auditEvent(null, 'robot'));
        $this->assertViolation(self::FOREIGN_KEY, 'audit_events_organization_fkey', fn () => $this->auditEvent(Uuid::v7()->toRfc4122()));
        $this->assertViolation('22P02', 'inet', fn () => $this->auditEvent(null, ip: 'not-an-ip'));
    }

    /**
     * @param callable(): mixed $statement
     */
    private function assertViolation(string $sqlState, string $detail, callable $statement): void
    {
        $this->db->createSavepoint('expected_violation');
        try {
            $statement();
            self::fail(\sprintf('Expected SQLSTATE %s (%s), but the statement succeeded.', $sqlState, $detail));
        } catch (DriverException $e) {
            self::assertSame($sqlState, $e->getSQLState(), $e->getMessage());
            self::assertStringContainsString($detail, $e->getMessage());
        } finally {
            $this->db->rollbackSavepoint('expected_violation');
        }
    }

    private function user(?string $email = null): string
    {
        $id = Uuid::v7()->toRfc4122();
        $this->db->insert('users', [
            'id' => $id,
            'email' => $email ?? $id.'@example.com',
            'password_hash' => 'hash',
            'display_name' => 'Test User',
            'created_at' => '2026-10-22T00:00:00Z',
        ]);

        return $id;
    }

    private function organization(string $currency = 'EUR'): string
    {
        $id = Uuid::v7()->toRfc4122();
        $this->db->insert('organizations', ['id' => $id, 'name' => 'Org '.$id, 'currency' => $currency, 'timezone' => 'Europe/Warsaw', 'created_at' => '2026-10-22T00:00:00Z']);

        return $id;
    }

    private function membership(string $org, string $user, string $role = 'ADMIN', string $status = 'ACTIVE', ?string $removedAt = null): string
    {
        $id = Uuid::v7()->toRfc4122();
        $this->db->insert('memberships', ['id' => $id, 'organization_id' => $org, 'user_id' => $user, 'role' => $role, 'status' => $status, 'created_at' => '2026-10-22T00:00:00Z', 'removed_at' => $removedAt]);

        return $id;
    }

    private function pipeline(string $org): string
    {
        $id = Uuid::v7()->toRfc4122();
        $this->db->insert('pipelines', ['id' => $id, 'organization_id' => $org]);

        return $id;
    }

    private function stage(string $org, string $pipeline, string $name, int $position, bool $archived = false): string
    {
        $id = Uuid::v7()->toRfc4122();
        $this->db->insert('pipeline_stages', ['id' => $id, 'organization_id' => $org, 'pipeline_id' => $pipeline, 'name' => $name, 'position' => $position, 'archived_at' => $archived ? '2026-10-22T00:00:00Z' : null]);

        return $id;
    }

    private function auditEvent(?string $org, string $actorType = 'system', ?string $ip = '192.0.2.10'): string
    {
        $id = Uuid::v7()->toRfc4122();
        $this->db->insert('audit_events', [
            'id' => $id,
            'organization_id' => $org,
            'occurred_at' => '2026-10-22T00:00:00Z',
            'actor_type' => $actorType,
            'action' => 'organization.created',
            'entity_type' => 'organization',
            'changes' => '{}',
            'ip' => $ip,
        ]);

        return $id;
    }
}
