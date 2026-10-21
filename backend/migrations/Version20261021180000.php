<?php

declare(strict_types=1);

namespace DoctrineMigrations;

use Doctrine\DBAL\Schema\Schema;
use Doctrine\Migrations\AbstractMigration;

/**
 * Schema baseline of the development foundation (FCRM-FND-004).
 *
 * Creates the single-row table that records the baseline, so migration state
 * and connectivity can be verified before the core schema exists (FND-007).
 */
final class Version20261021180000 extends AbstractMigration
{
    public function getDescription(): string
    {
        return 'Create the schema_baseline table (FCRM-FND-004).';
    }

    public function up(Schema $schema): void
    {
        $this->addSql('CREATE TABLE schema_baseline (id SMALLINT NOT NULL, baseline VARCHAR(64) NOT NULL, created_at TIMESTAMP(0) WITH TIME ZONE NOT NULL, PRIMARY KEY (id), CONSTRAINT schema_baseline_single_row CHECK (id = 1))');
        $this->addSql("INSERT INTO schema_baseline (id, baseline, created_at) VALUES (1, 'FCRM-FND-004', now())");
    }

    public function down(Schema $schema): void
    {
        $this->addSql('DROP TABLE schema_baseline');
    }
}
