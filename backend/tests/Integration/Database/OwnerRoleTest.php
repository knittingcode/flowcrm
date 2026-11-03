<?php

declare(strict_types=1);

namespace App\Tests\Integration\Database;

use App\Tests\Support\Database\TestDatabase;
use App\Tests\Support\TypedValues;
use Doctrine\DBAL\Connection;
use Doctrine\DBAL\Exception\DriverException;
use PHPUnit\Framework\Attributes\DataProvider;
use PHPUnit\Framework\TestCase;

/**
 * The schema owner flowcrm_owner (ADR-018): it runs migrations, its new
 * objects give the runtime role nothing (default-deny), and it has none of
 * the superuser's powers. It can still disable the audit trigger of a table
 * it owns: the documented limit of the role separation.
 */
final class OwnerRoleTest extends TestCase
{
    use TypedValues;

    private Connection $owner;

    protected function setUp(): void
    {
        $this->owner = TestDatabase::owner();
        $this->owner->beginTransaction();
    }

    protected function tearDown(): void
    {
        $this->owner->rollBack();
        $this->owner->close();
    }

    public function testItChangesTheSchema(): void
    {
        $this->owner->executeStatement('CREATE TABLE owner_probe (id int PRIMARY KEY)');
        $this->owner->executeStatement('ALTER TABLE owner_probe ADD COLUMN v text');
        $this->owner->executeStatement('DROP TABLE owner_probe');
        $this->addToAssertionCount(1);
    }

    public function testNewObjectsGiveTheRuntimeRoleNothing(): void
    {
        $this->owner->executeStatement('CREATE TABLE owner_probe (id int GENERATED ALWAYS AS IDENTITY, v text)');
        $this->owner->executeStatement('CREATE VIEW owner_probe_view AS SELECT * FROM owner_probe');
        $this->owner->executeStatement('CREATE FUNCTION owner_probe_f() RETURNS int LANGUAGE sql AS $$SELECT 1$$');

        $this->assertNoAccess("has_table_privilege('flowcrm_app', 'owner_probe', 'SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER')");
        $this->assertNoAccess("has_table_privilege('flowcrm_app', 'owner_probe_view', 'SELECT')");
        $this->assertNoAccess("has_sequence_privilege('flowcrm_app', pg_get_serial_sequence('owner_probe', 'id'), 'USAGE, SELECT, UPDATE')");
        $this->assertNoAccess("has_function_privilege('flowcrm_app', 'owner_probe_f()', 'EXECUTE')");
        $this->assertNoAccess("has_table_privilege('public', 'owner_probe', 'SELECT')");
    }

    /**
     * @return iterable<string, array{string, string}>
     */
    public static function superuserPowers(): iterable
    {
        yield 'skip triggers' => ['SET LOCAL session_replication_role = replica', 'permission denied to set parameter'];
        yield 'COPY FROM PROGRAM' => ["COPY users (id) FROM PROGRAM 'id'", 'permission denied to COPY to or from an external program'];
        yield 'read a server file' => ["SELECT pg_read_file('/etc/passwd')", 'permission denied for function pg_read_file'];
        yield 'CREATE ROLE' => ['CREATE ROLE owner_evil', 'permission denied to create role'];
        yield 'SET ROLE flowcrm' => ['SET ROLE flowcrm', 'permission denied to set role'];
        yield 'ALTER ROLE SUPERUSER' => ['ALTER ROLE flowcrm_owner SUPERUSER', 'permission denied'];
    }

    #[DataProvider('superuserPowers')]
    public function testItHasNoSuperuserPowers(string $sql, string $message): void
    {
        $this->owner->createSavepoint('power');
        try {
            $this->owner->executeStatement($sql);
            self::fail("the owner could run: {$sql}");
        } catch (DriverException $e) {
            self::assertStringContainsStringIgnoringCase($message, $e->getMessage());
        } finally {
            $this->owner->rollbackSavepoint('power');
        }
    }

    public function testItCannotCreateDatabases(): void
    {
        self::assertFalse($this->owner->fetchOne('SELECT rolcreatedb OR rolsuper FROM pg_roles WHERE rolname = current_user'));
    }

    /** Documented limit (ADR-018): the owner of audit_events can disable its trigger. */
    public function testItCanDisableTheAuditTriggerOfATableItOwns(): void
    {
        $this->owner->executeStatement('ALTER TABLE audit_events DISABLE TRIGGER audit_events_append_only');
        self::assertSame('D', $this->owner->fetchOne("SELECT tgenabled::text FROM pg_trigger WHERE tgname = 'audit_events_append_only'"));
    }

    private function assertNoAccess(string $check): void
    {
        self::assertFalse($this->owner->fetchOne('SELECT '.$check), $check);
    }
}
