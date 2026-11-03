<?php

declare(strict_types=1);

namespace DoctrineMigrations;

use Doctrine\DBAL\Schema\Schema;
use Doctrine\Migrations\AbstractMigration;

/**
 * Core schema (FCRM-FND-007, FCRM-003 section F): users, organizations,
 * memberships, the pipeline and its stages, and the append-only audit log.
 *
 * Constraints the ORM mapping cannot express are created here and tested in
 * tests/Integration/Database: CHECK constraints, unique indexes on lower(),
 * the deferrable stage position constraint and the audit trigger. Composite
 * tenant foreign keys reference UNIQUE (organization_id, id), so a row can
 * never point to a row of another organization.
 */
final class Version20261022000000 extends AbstractMigration
{
    public function getDescription(): string
    {
        return 'Create the core schema: users, organizations, memberships, pipelines, pipeline_stages, audit_events (FCRM-FND-007).';
    }

    public function up(Schema $schema): void
    {
        $this->addSql(<<<'SQL'
            CREATE TABLE users (
                id UUID NOT NULL,
                email TEXT NOT NULL,
                password_hash TEXT NOT NULL,
                display_name TEXT NOT NULL,
                disabled_at TIMESTAMP(0) WITH TIME ZONE DEFAULT NULL,
                password_changed_at TIMESTAMP(0) WITH TIME ZONE DEFAULT NULL,
                created_at TIMESTAMP(0) WITH TIME ZONE NOT NULL,
                PRIMARY KEY (id),
                CONSTRAINT users_email_length_check CHECK (length(email) <= 254)
            )
            SQL);
        $this->addSql('CREATE UNIQUE INDEX users_email_lower_key ON users (lower(email))');

        $this->addSql(<<<'SQL'
            CREATE TABLE organizations (
                id UUID NOT NULL,
                name TEXT NOT NULL,
                currency CHAR(3) NOT NULL,
                timezone TEXT NOT NULL,
                created_at TIMESTAMP(0) WITH TIME ZONE NOT NULL,
                PRIMARY KEY (id),
                CONSTRAINT organizations_currency_check CHECK (currency IN ('EUR', 'PLN', 'USD', 'GBP', 'CHF', 'SEK', 'NOK', 'DKK', 'CZK'))
            )
            SQL);

        $this->addSql(<<<'SQL'
            CREATE TABLE memberships (
                id UUID NOT NULL,
                organization_id UUID NOT NULL,
                user_id UUID NOT NULL,
                role TEXT NOT NULL,
                status TEXT NOT NULL,
                created_at TIMESTAMP(0) WITH TIME ZONE NOT NULL,
                removed_at TIMESTAMP(0) WITH TIME ZONE DEFAULT NULL,
                PRIMARY KEY (id),
                CONSTRAINT memberships_organization_user_key UNIQUE (organization_id, user_id),
                CONSTRAINT memberships_organization_id_key UNIQUE (organization_id, id),
                CONSTRAINT memberships_role_check CHECK (role IN ('ADMIN', 'MANAGER', 'REP')),
                CONSTRAINT memberships_status_check CHECK (status IN ('ACTIVE', 'REMOVED')),
                CONSTRAINT memberships_removed_at_check CHECK ((status = 'REMOVED') = (removed_at IS NOT NULL)),
                CONSTRAINT memberships_organization_fkey FOREIGN KEY (organization_id) REFERENCES organizations (id),
                CONSTRAINT memberships_user_fkey FOREIGN KEY (user_id) REFERENCES users (id)
            )
            SQL);
        $this->addSql("CREATE INDEX memberships_active_user_idx ON memberships (user_id) WHERE status = 'ACTIVE'");

        $this->addSql(<<<'SQL'
            CREATE TABLE pipelines (
                id UUID NOT NULL,
                organization_id UUID NOT NULL,
                PRIMARY KEY (id),
                CONSTRAINT pipelines_organization_key UNIQUE (organization_id),
                CONSTRAINT pipelines_organization_id_key UNIQUE (organization_id, id),
                CONSTRAINT pipelines_organization_fkey FOREIGN KEY (organization_id) REFERENCES organizations (id)
            )
            SQL);

        $this->addSql(<<<'SQL'
            CREATE TABLE pipeline_stages (
                id UUID NOT NULL,
                organization_id UUID NOT NULL,
                pipeline_id UUID NOT NULL,
                name TEXT NOT NULL,
                position INT NOT NULL,
                archived_at TIMESTAMP(0) WITH TIME ZONE DEFAULT NULL,
                PRIMARY KEY (id),
                CONSTRAINT pipeline_stages_organization_id_key UNIQUE (organization_id, id),
                CONSTRAINT pipeline_stages_pipeline_position_key UNIQUE (pipeline_id, position) DEFERRABLE INITIALLY DEFERRED,
                CONSTRAINT pipeline_stages_pipeline_fkey FOREIGN KEY (organization_id, pipeline_id) REFERENCES pipelines (organization_id, id)
            )
            SQL);
        $this->addSql('CREATE INDEX pipeline_stages_organization_pipeline_idx ON pipeline_stages (organization_id, pipeline_id)');
        // Active stage names are unique per pipeline regardless of case. The
        // index has expression columns only: DBAL's schema introspection drops
        // expressions but keeps plain columns, and would report a different
        // index (UNIQUE (pipeline_id) WHERE ...) to schema validation.
        $this->addSql('CREATE UNIQUE INDEX pipeline_stages_active_name_key ON pipeline_stages ((pipeline_id::text), lower(name)) WHERE archived_at IS NULL');

        $this->addSql(<<<'SQL'
            CREATE TABLE audit_events (
                id UUID NOT NULL,
                organization_id UUID DEFAULT NULL,
                occurred_at TIMESTAMP(0) WITH TIME ZONE NOT NULL,
                actor_type TEXT NOT NULL,
                actor_user_id UUID DEFAULT NULL,
                actor_role TEXT DEFAULT NULL,
                action TEXT NOT NULL,
                entity_type TEXT NOT NULL,
                entity_id UUID DEFAULT NULL,
                changes JSONB NOT NULL,
                request_id UUID DEFAULT NULL,
                ip INET DEFAULT NULL,
                PRIMARY KEY (id),
                CONSTRAINT audit_events_actor_type_check CHECK (actor_type IN ('user', 'platform_operator', 'system')),
                CONSTRAINT audit_events_organization_fkey FOREIGN KEY (organization_id) REFERENCES organizations (id)
            )
            SQL);
        $this->addSql('CREATE INDEX audit_events_organization_time_idx ON audit_events (organization_id, occurred_at DESC, id DESC)');
        $this->addSql('CREATE INDEX audit_events_organization_entity_idx ON audit_events (organization_id, entity_type, entity_id, occurred_at DESC)');

        // Append-only audit log: no UPDATE, DELETE or TRUNCATE, for any role.
        $this->addSql(<<<'SQL'
            CREATE FUNCTION audit_events_reject_change() RETURNS trigger LANGUAGE plpgsql AS $$
            BEGIN
                RAISE EXCEPTION 'audit_events is append-only: % is not allowed', TG_OP USING ERRCODE = 'insufficient_privilege';
            END
            $$
            SQL);
        $this->addSql('CREATE TRIGGER audit_events_append_only BEFORE UPDATE OR DELETE ON audit_events FOR EACH ROW EXECUTE FUNCTION audit_events_reject_change()');
        $this->addSql('CREATE TRIGGER audit_events_no_truncate BEFORE TRUNCATE ON audit_events FOR EACH STATEMENT EXECUTE FUNCTION audit_events_reject_change()');
    }

    public function down(Schema $schema): void
    {
        $this->addSql('DROP TABLE audit_events');
        $this->addSql('DROP FUNCTION audit_events_reject_change()');
        $this->addSql('DROP TABLE pipeline_stages');
        $this->addSql('DROP TABLE pipelines');
        $this->addSql('DROP TABLE memberships');
        $this->addSql('DROP TABLE organizations');
        $this->addSql('DROP TABLE users');
    }
}
