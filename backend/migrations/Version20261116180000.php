<?php

declare(strict_types=1);

namespace DoctrineMigrations;

use Doctrine\DBAL\Schema\Schema;
use Doctrine\Migrations\AbstractMigration;

/**
 * Accounts (customer companies), the first CRM table of the MVP
 * (docs/product/MVP.md). A tenant table like the core ones: UNIQUE
 * (organization_id, id), so that contacts and opportunities can reference an
 * account of the same organization only.
 *
 * Runtime privileges of flowcrm_app (ADR-018): SELECT, INSERT and UPDATE.
 * Accounts are archived, never deleted, so the runtime role gets no DELETE.
 */
final class Version20261116180000 extends AbstractMigration
{
    public function getDescription(): string
    {
        return 'Create accounts (customer companies) and grant the runtime role its privileges.';
    }

    public function up(Schema $schema): void
    {
        $this->addSql(<<<'SQL'
            CREATE TABLE accounts (
                id UUID NOT NULL,
                organization_id UUID NOT NULL,
                name TEXT NOT NULL,
                website TEXT DEFAULT NULL,
                email TEXT DEFAULT NULL,
                phone TEXT DEFAULT NULL,
                created_at TIMESTAMP(0) WITH TIME ZONE NOT NULL,
                updated_at TIMESTAMP(0) WITH TIME ZONE NOT NULL,
                archived_at TIMESTAMP(0) WITH TIME ZONE DEFAULT NULL,
                PRIMARY KEY (id),
                CONSTRAINT accounts_organization_id_key UNIQUE (organization_id, id),
                CONSTRAINT accounts_name_check CHECK (length(btrim(name)) BETWEEN 1 AND 200),
                CONSTRAINT accounts_website_length_check CHECK (length(website) <= 2048),
                CONSTRAINT accounts_email_length_check CHECK (length(email) <= 254),
                CONSTRAINT accounts_phone_length_check CHECK (length(phone) <= 50),
                CONSTRAINT accounts_organization_fkey FOREIGN KEY (organization_id) REFERENCES organizations (id)
            )
            SQL);
        $this->addSql('GRANT SELECT, INSERT, UPDATE ON accounts TO flowcrm_app');
    }

    public function down(Schema $schema): void
    {
        $this->addSql('DROP TABLE accounts');
    }
}
