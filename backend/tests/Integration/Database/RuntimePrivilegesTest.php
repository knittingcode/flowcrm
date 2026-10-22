<?php

declare(strict_types=1);

namespace App\Tests\Integration\Database;

use App\Tests\Support\Database\TestDatabase;
use App\Tests\Support\TypedValues;
use Doctrine\DBAL\Connection;
use Doctrine\DBAL\DriverManager;
use Doctrine\DBAL\Exception\DriverException;
use PHPUnit\Framework\Attributes\DataProvider;
use Symfony\Bundle\FrameworkBundle\Test\KernelTestCase;

/**
 * What the runtime role flowcrm_app may and may not do (ADR-018), through
 * the kernel's own connection: the role, password and SCRAM authentication
 * the API uses. Every case runs in a transaction that is rolled back.
 */
final class RuntimePrivilegesTest extends KernelTestCase
{
    use TypedValues;

    private const DENIED = 'permission denied';
    private const AUDIT = "INSERT INTO audit_events (id, occurred_at, actor_type, action, entity_type, changes) VALUES (gen_random_uuid(), now(), 'system', 'test', 'test', '{}')";

    public function testTheConnectionUsesTheRuntimeRole(): void
    {
        $role = $this->db()->fetchAssociative('SELECT current_user AS name, rolsuper, rolinherit, rolcreaterole, rolcreatedb, rolbypassrls FROM pg_roles WHERE rolname = current_user');

        self::assertSame(['name' => 'flowcrm_app', 'rolsuper' => false, 'rolinherit' => false, 'rolcreaterole' => false, 'rolcreatedb' => false, 'rolbypassrls' => false], $role);
        self::assertSame(0, self::int($this->db()->fetchOne("SELECT count(*) FROM pg_auth_members WHERE member = 'flowcrm_app'::regrole")));
    }

    /**
     * @return iterable<string, array{string}>
     */
    public static function allowed(): iterable
    {
        yield 'read every business table' => ['SELECT (SELECT count(*) FROM users) + (SELECT count(*) FROM organizations) + (SELECT count(*) FROM memberships) + (SELECT count(*) FROM pipelines) + (SELECT count(*) FROM pipeline_stages)'];
        yield 'write a user' => ["INSERT INTO users (id, email, password_hash, display_name, created_at) VALUES (gen_random_uuid(), 'rt@example.com', 'h', 'R', now()); UPDATE users SET display_name = 'S' WHERE email = 'rt@example.com'; DELETE FROM users WHERE email = 'rt@example.com'"];
        yield 'append and read audit events' => [self::AUDIT.'; SELECT count(*) FROM audit_events'];
        yield 'session row lifecycle with row lock' => ["INSERT INTO sessions VALUES ('rt', 'd', 1, 1); SELECT 1 FROM sessions WHERE sess_id = 'rt' FOR UPDATE; UPDATE sessions SET sess_time = 2 WHERE sess_id = 'rt'; DELETE FROM sessions WHERE sess_id = 'rt'"];
        yield 'cache upsert and delete' => ["INSERT INTO cache_items VALUES ('rt:k', 'v', NULL, 1) ON CONFLICT (item_id) DO UPDATE SET item_data = EXCLUDED.item_data; DELETE FROM cache_items WHERE item_id = 'rt:k'"];
        yield 'read the migration status' => ['SELECT count(*) FROM doctrine_migration_versions'];
    }

    #[DataProvider('allowed')]
    public function testAllowed(string $sql): void
    {
        $db = $this->db();
        $db->beginTransaction();
        try {
            $db->executeStatement($sql);
            $this->addToAssertionCount(1);
        } finally {
            $db->rollBack();
        }
    }

    /**
     * @return iterable<string, array{string, string}> SQL, expected message
     */
    public static function denied(): iterable
    {
        yield 'UPDATE audit_events' => ["UPDATE audit_events SET action = 'x'", 'permission denied for table audit_events'];
        yield 'DELETE audit_events' => ['DELETE FROM audit_events', 'permission denied for table audit_events'];
        yield 'TRUNCATE audit_events' => ['TRUNCATE audit_events', 'permission denied for table audit_events'];
        yield 'lock audit_events exclusively' => ['LOCK TABLE audit_events IN ACCESS EXCLUSIVE MODE', 'permission denied for table audit_events'];
        yield 'disable the audit triggers' => ['ALTER TABLE audit_events DISABLE TRIGGER ALL', 'must be owner of table audit_events'];
        yield 'skip triggers (session_replication_role)' => ['SET LOCAL session_replication_role = replica', 'permission denied to set parameter'];
        yield 'TRUNCATE a business table' => ['TRUNCATE users CASCADE', 'permission denied for table users'];
        yield 'CREATE TABLE' => ['CREATE TABLE rt_new (id int)', 'permission denied for schema public'];
        yield 'CREATE FUNCTION' => ['CREATE FUNCTION rt_f() RETURNS int LANGUAGE sql AS $$SELECT 1$$', 'permission denied for schema public'];
        yield 'ALTER TABLE' => ['ALTER TABLE users ADD COLUMN rt int', 'must be owner of table users'];
        yield 'DROP TABLE' => ['DROP TABLE users', 'must be owner of table users'];
        yield 'CREATE TEMP TABLE' => ['CREATE TEMP TABLE rt_tmp (id int)', 'permission denied to create temporary tables'];
        yield 'CREATE SCHEMA' => ['CREATE SCHEMA rt', 'permission denied for database'];
        yield 'CREATE EXTENSION' => ['CREATE EXTENSION pgcrypto', self::DENIED];
        yield 'SET ROLE flowcrm_owner' => ['SET ROLE flowcrm_owner', 'permission denied to set role'];
        yield 'SET ROLE flowcrm (superuser)' => ['SET ROLE flowcrm', 'permission denied to set role'];
        yield 'ALTER ROLE SUPERUSER' => ['ALTER ROLE flowcrm_app SUPERUSER', self::DENIED];
        yield 'ALTER ROLE BYPASSRLS' => ['ALTER ROLE flowcrm_app BYPASSRLS', self::DENIED];
        yield 'CREATE ROLE' => ['CREATE ROLE rt_evil LOGIN', 'permission denied to create role'];
        yield 'COPY FROM PROGRAM' => ["COPY users (id) FROM PROGRAM 'id'", 'permission denied to COPY to or from an external program'];
        yield 'read a server file' => ["SELECT pg_read_file('/etc/passwd')", 'permission denied for function pg_read_file'];
        yield 'list a server directory' => ["SELECT pg_ls_dir('/')", 'permission denied for function pg_ls_dir'];
        yield 'call the audit trigger function' => ['SELECT audit_events_reject_change()', 'permission denied for function audit_events_reject_change'];
        yield 'read schema_baseline (not in the manifest)' => ['SELECT * FROM schema_baseline', 'permission denied for table schema_baseline'];
        yield 'change the migration history' => ["INSERT INTO doctrine_migration_versions (version) VALUES ('x')", 'permission denied for table doctrine_migration_versions'];
    }

    #[DataProvider('denied')]
    public function testDenied(string $sql, string $message): void
    {
        $db = $this->db();
        $db->beginTransaction();
        try {
            $db->executeStatement($sql);
            self::fail("the runtime role could run: {$sql}");
        } catch (DriverException $e) {
            self::assertStringContainsStringIgnoringCase($message, $e->getMessage());
        } finally {
            $db->rollBack();
        }
    }

    /** GRANT on objects it does not own has no effect (PostgreSQL only warns). */
    public function testItCannotGrantPrivileges(): void
    {
        $db = $this->db();
        $db->beginTransaction();
        try {
            $db->executeStatement('GRANT ALL ON users, audit_events TO PUBLIC');
            $db->executeStatement('GRANT TRUNCATE, UPDATE, DELETE ON audit_events TO flowcrm_app');
            self::assertFalse($db->fetchOne("SELECT has_table_privilege('public', 'users', 'SELECT')"));
            self::assertFalse($db->fetchOne("SELECT has_table_privilege('flowcrm_app', 'audit_events', 'UPDATE, DELETE, TRUNCATE')"));
        } finally {
            $db->rollBack();
        }
    }

    /** Network logins need the role's own password; the runtime password opens no other role. */
    public function testItsPasswordOpensNoOtherRole(): void
    {
        $runtimePassword = $this->db()->getParams()['password'] ?? null;
        self::assertIsString($runtimePassword);
        foreach (['flowcrm', TestDatabase::OWNER] as $role) {
            foreach (['' => 'no password', $runtimePassword => 'the runtime password'] as $password => $label) {
                try {
                    DriverManager::getConnection(['driver' => 'pdo_pgsql', 'host' => self::string($this->db()->getParams()['host'] ?? null), 'dbname' => 'flowcrm', 'user' => $role, 'password' => $password, 'serverVersion' => '18'])->fetchOne('SELECT 1');
                    self::fail("{$role} accepted {$label}");
                } catch (DriverException $e) {
                    self::assertMatchesRegularExpression('/password authentication failed|no password supplied/', $e->getMessage(), "{$role} with {$label}");
                }
            }
        }
    }

    /**
     * @return iterable<string, array{string}>
     */
    public static function maintenanceDatabases(): iterable
    {
        yield 'postgres' => ['postgres'];
        yield 'template1' => ['template1'];
    }

    /** The runtime role logs in to the application database only (no CONNECT, no TEMPORARY elsewhere). */
    #[DataProvider('maintenanceDatabases')]
    public function testItCannotConnectToAMaintenanceDatabase(string $database): void
    {
        $connect = fn (string $dbname): Connection => DriverManager::getConnection([
            'driver' => 'pdo_pgsql',
            'host' => self::string($this->db()->getParams()['host'] ?? null),
            'dbname' => $dbname,
            'user' => 'flowcrm_app',
            'password' => self::string($this->db()->getParams()['password'] ?? null),
            'serverVersion' => '18',
        ]);
        // Control: the same credentials open the application database.
        self::assertSame('flowcrm_app', $connect('flowcrm')->fetchOne('SELECT current_user'));
        try {
            $connect($database)->fetchOne('SELECT 1');
            self::fail("flowcrm_app could connect to {$database}");
        } catch (DriverException $e) {
            self::assertStringContainsString('permission denied for database "'.$database.'"', $e->getMessage());
        }
    }

    private function db(): Connection
    {
        $db = self::getContainer()->get('doctrine.dbal.default_connection');
        self::assertInstanceOf(Connection::class, $db);

        return $db;
    }
}
