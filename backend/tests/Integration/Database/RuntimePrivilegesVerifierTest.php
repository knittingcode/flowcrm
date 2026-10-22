<?php

declare(strict_types=1);

namespace App\Tests\Integration\Database;

use App\Shared\Infrastructure\Database\RuntimePrivileges;
use App\Tests\Support\Database\TestDatabase;
use Doctrine\DBAL\Connection;
use PHPUnit\Framework\Attributes\DataProvider;
use Symfony\Bundle\FrameworkBundle\Console\Application;
use Symfony\Bundle\FrameworkBundle\Test\KernelTestCase;
use Symfony\Component\Console\Tester\CommandTester;

/**
 * The privilege manifest check (RuntimePrivileges). The migrated test
 * database matches the manifest; each weakening below, made in a
 * transaction of the owner or the bootstrap superuser and rolled back, is
 * reported by a verifier on that same connection.
 */
final class RuntimePrivilegesVerifierTest extends KernelTestCase
{
    public function testTheMigratedDatabaseMatchesTheManifest(): void
    {
        $verifier = self::getContainer()->get(RuntimePrivileges::class);
        self::assertInstanceOf(RuntimePrivileges::class, $verifier);

        self::assertSame([], $verifier->violations());
        self::assertSame('flowcrm_app', $verifier->currentRole());
    }

    public function testTheCommandPassesForTheRuntimeRole(): void
    {
        $tester = new CommandTester(new Application(self::bootKernel())->find('app:database:verify-privileges'));

        self::assertSame(0, $tester->execute(['--runtime' => true]));
        self::assertStringContainsString('OK: the database roles and runtime privileges match', $tester->getDisplay());
    }

    /**
     * @return iterable<string, array{'owner'|'admin', string, string}> who, SQL, expected violation
     */
    public static function weakenings(): iterable
    {
        yield 'extra privilege on a business table' => ['owner', 'GRANT TRUNCATE ON users TO flowcrm_app', 'table users: flowcrm_app has [DELETE, INSERT, SELECT, TRUNCATE, UPDATE]'];
        yield 'audit events writable' => ['owner', 'GRANT UPDATE, DELETE ON audit_events TO flowcrm_app', 'table audit_events: flowcrm_app has [DELETE, INSERT, SELECT, UPDATE]'];
        yield 'missing privilege' => ['owner', 'REVOKE INSERT ON audit_events FROM flowcrm_app', 'table audit_events: flowcrm_app has [SELECT], the manifest lists [INSERT, SELECT]'];
        yield 'PUBLIC privilege' => ['owner', 'GRANT SELECT ON users TO PUBLIC', 'table users grants privileges to PUBLIC or with grant option'];
        yield 'grant option' => ['owner', 'GRANT SELECT ON users TO flowcrm_app WITH GRANT OPTION', 'table users grants privileges to PUBLIC or with grant option'];
        yield 'column privilege' => ['owner', 'GRANT UPDATE (display_name) ON users TO PUBLIC', 'table users has column privileges'];
        yield 'unclassified new table' => ['owner', 'CREATE TABLE unlisted (id int)', 'table unlisted is not listed in the runtime privilege manifest'];
        yield 'unclassified new sequence' => ['owner', 'CREATE SEQUENCE unlisted_seq', 'sequence unlisted_seq is not listed in the runtime privilege manifest'];
        yield 'default privileges for new tables' => ['owner', 'ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO flowcrm_app', 'default privileges of flowcrm_owner give new tables'];
        // Granting it back restores PostgreSQL's built-in default (the entry disappears).
        yield 'new functions executable by PUBLIC' => ['owner', 'ALTER DEFAULT PRIVILEGES GRANT EXECUTE ON FUNCTIONS TO PUBLIC', 'new functions of flowcrm_owner would be executable by PUBLIC'];
        yield 'new functions executable by the runtime role' => ['owner', 'ALTER DEFAULT PRIVILEGES GRANT EXECUTE ON FUNCTIONS TO flowcrm_app', 'default privileges of flowcrm_owner give new functions'];
        yield 'function executable by PUBLIC' => ['owner', 'GRANT EXECUTE ON FUNCTION audit_events_reject_change() TO PUBLIC', 'function audit_events_reject_change is executable'];
        yield 'schema CREATE for the runtime role' => ['owner', 'GRANT CREATE ON SCHEMA public TO flowcrm_app', 'flowcrm_app may create objects in schema public'];
        yield 'schema privilege for PUBLIC' => ['owner', 'GRANT USAGE ON SCHEMA public TO PUBLIC', 'PUBLIC has privileges on schema public'];
        yield 'database TEMPORARY' => ['admin', 'GRANT TEMPORARY ON DATABASE flowcrm TO flowcrm_app', 'flowcrm_app may create schemas or temporary tables'];
        yield 'database privilege for PUBLIC' => ['admin', 'GRANT CONNECT ON DATABASE flowcrm TO PUBLIC', 'PUBLIC has privileges on the database'];
        yield 'object owned by the superuser' => ['admin', 'ALTER TABLE sessions OWNER TO flowcrm', 'table sessions is owned by flowcrm'];
        yield 'runtime role inherits' => ['admin', 'ALTER ROLE flowcrm_app INHERIT', 'flowcrm_app inherits privileges'];
        yield 'runtime role is a superuser' => ['admin', 'ALTER ROLE flowcrm_app SUPERUSER', 'role flowcrm_app has rolsuper'];
        yield 'owner may create roles' => ['admin', 'ALTER ROLE flowcrm_owner CREATEROLE', 'role flowcrm_owner has rolcreaterole'];
        yield 'runtime role member of the owner' => ['admin', 'GRANT flowcrm_owner TO flowcrm_app', 'role flowcrm_app is a member of flowcrm_owner'];
    }

    /**
     * @param 'owner'|'admin' $who
     */
    #[DataProvider('weakenings')]
    public function testEachWeakeningIsReported(string $who, string $sql, string $violation): void
    {
        $connection = 'owner' === $who ? TestDatabase::owner() : TestDatabase::admin();
        $connection->beginTransaction();
        try {
            self::assertSame([], $this->verifier($connection)->violations(), 'clean before the change');
            $connection->executeStatement($sql);

            $violations = $this->verifier($connection)->violations();

            self::assertNotSame([], $violations);
            self::assertStringContainsString($violation, implode("\n", $violations));
        } finally {
            $connection->rollBack();
            $connection->close();
        }
    }

    private function verifier(Connection $connection): RuntimePrivileges
    {
        return new RuntimePrivileges($connection, \dirname(__DIR__, 3).'/config/database/runtime-privileges.yaml');
    }
}
