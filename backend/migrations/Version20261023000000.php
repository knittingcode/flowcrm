<?php

declare(strict_types=1);

namespace DoctrineMigrations;

use Doctrine\DBAL\Schema\Schema;
use Doctrine\Migrations\AbstractMigration;

/**
 * Runtime privileges of flowcrm_app for the tables created so far
 * (FCRM-FND-009, ADR-018), exactly as config/database/runtime-privileges.yaml
 * lists them. Runs as the schema owner flowcrm_owner. Later migrations
 * grant the privileges of the objects they create.
 *
 * audit_events is append-only for the runtime role: SELECT and INSERT, so
 * PostgreSQL itself refuses UPDATE, DELETE and TRUNCATE before the trigger.
 */
final class Version20261023000000 extends AbstractMigration
{
    private const RUNTIME = 'flowcrm_app';
    private const READ_WRITE = ['users', 'organizations', 'memberships', 'pipelines', 'pipeline_stages', 'sessions', 'cache_items'];

    public function getDescription(): string
    {
        return 'Grant the runtime role flowcrm_app its privileges on the existing tables (FCRM-FND-009).';
    }

    public function up(Schema $schema): void
    {
        $this->abortIf(
            false === $this->connection->fetchOne('SELECT 1 FROM pg_roles WHERE rolname = ?', [self::RUNTIME]),
            'The role flowcrm_app does not exist. New volumes create it on initialisation; existing ones need the explicit upgrade (make db-upgrade-roles, ADR-018).',
        );

        foreach (self::READ_WRITE as $table) {
            $this->addSql(\sprintf('GRANT SELECT, INSERT, UPDATE, DELETE ON %s TO %s', $table, self::RUNTIME));
        }
        $this->addSql(\sprintf('GRANT SELECT, INSERT ON audit_events TO %s', self::RUNTIME));
        $this->addSql(\sprintf('GRANT SELECT ON doctrine_migration_versions TO %s', self::RUNTIME));
        // Trigger functions run without EXECUTE of the caller; nobody calls them directly.
        $this->addSql('REVOKE EXECUTE ON FUNCTION audit_events_reject_change() FROM PUBLIC');
    }

    public function down(Schema $schema): void
    {
        foreach ([...self::READ_WRITE, 'audit_events', 'doctrine_migration_versions'] as $table) {
            $this->addSql(\sprintf('REVOKE ALL ON %s FROM %s', $table, self::RUNTIME));
        }
    }
}
