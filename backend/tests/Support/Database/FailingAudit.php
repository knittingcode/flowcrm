<?php

declare(strict_types=1);

namespace App\Tests\Support\Database;

use Symfony\Component\Uid\Uuid;

/**
 * Makes writes to the audit log fail for a while: a trigger of the schema
 * owner that raises for the matching events, removed afterwards. Used to
 * show that no audited change happens without its audit event.
 */
trait FailingAudit
{
    /**
     * Runs $action while every audit event about $entity fails to be written.
     *
     * @template T
     *
     * @param callable(): T $action
     *
     * @return T
     */
    protected function whileAuditFailsFor(Uuid $entity, callable $action): mixed
    {
        return $this->whileAuditFails(\sprintf("NEW.entity_id = '%s'", $entity->toRfc4122()), $action);
    }

    /**
     * Runs $action while every audit event matching $when (an SQL condition
     * on NEW, from test code only) fails to be written.
     *
     * @template T
     *
     * @param callable(): T $action
     *
     * @return T
     */
    protected function whileAuditFails(string $when, callable $action): mixed
    {
        $owner = TestDatabase::owner();
        $owner->executeStatement("CREATE OR REPLACE FUNCTION test_audit_unavailable() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'audit storage unavailable (test)'; END $$");
        $owner->executeStatement(\sprintf('CREATE TRIGGER test_audit_unavailable BEFORE INSERT ON audit_events FOR EACH ROW WHEN (%s) EXECUTE FUNCTION test_audit_unavailable()', $when));
        try {
            return $action();
        } finally {
            $owner->executeStatement('DROP TRIGGER test_audit_unavailable ON audit_events');
            $owner->executeStatement('DROP FUNCTION test_audit_unavailable()');
            $owner->close();
        }
    }
}
