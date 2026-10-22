<?php

declare(strict_types=1);

namespace DoctrineMigrations;

use Doctrine\DBAL\Schema\Schema;
use Doctrine\Migrations\AbstractMigration;

/**
 * Session and cache storage (FCRM-FND-008, FCRM-003 section F): the tables
 * of Symfony's PdoSessionHandler and DoctrineDbalAdapter, exactly as their
 * schema listeners define them (doctrine:schema:validate fails otherwise).
 * Only adds tables; the core schema is not touched.
 */
final class Version20261022100000 extends AbstractMigration
{
    public function getDescription(): string
    {
        return 'Create the sessions and cache_items tables used by Symfony (FCRM-FND-008).';
    }

    public function up(Schema $schema): void
    {
        $this->addSql(<<<'SQL'
            CREATE TABLE sessions (
                sess_id VARCHAR(128) NOT NULL,
                sess_data BYTEA NOT NULL,
                sess_lifetime INT NOT NULL,
                sess_time INT NOT NULL,
                PRIMARY KEY (sess_id)
            )
            SQL);
        // sess_lifetime holds the expiry time; garbage collection deletes by it.
        $this->addSql('CREATE INDEX sess_lifetime_idx ON sessions (sess_lifetime)');
        $this->addSql(<<<'SQL'
            CREATE TABLE cache_items (
                item_id VARCHAR(255) NOT NULL,
                item_data BYTEA NOT NULL,
                item_lifetime INT DEFAULT NULL,
                item_time INT NOT NULL,
                PRIMARY KEY (item_id)
            )
            SQL);
    }

    public function down(Schema $schema): void
    {
        $this->addSql('DROP TABLE cache_items');
        $this->addSql('DROP TABLE sessions');
    }
}
