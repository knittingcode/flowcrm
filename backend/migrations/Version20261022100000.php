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
 *
 * This migration creates and owns both tables. It never adopts an existing
 * one: if a relation named sessions, cache_items or sess_lifetime_idx
 * already exists, it aborts before any change, and the relation has to be
 * renamed by hand (docs/architecture/sessions-and-cache.md, "Existing
 * tables"). Nothing is dropped or altered.
 */
final class Version20261022100000 extends AbstractMigration
{
    private const NAMES = ['sessions', 'cache_items', 'sess_lifetime_idx'];

    public function getDescription(): string
    {
        return 'Create the sessions and cache_items tables used by Symfony (FCRM-FND-008).';
    }

    public function up(Schema $schema): void
    {
        $existing = $this->connection->fetchFirstColumn(
            'SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
              WHERE n.nspname = current_schema() AND c.relname IN (?, ?, ?) ORDER BY c.relname',
            self::NAMES,
        );
        $this->abortIf(
            [] !== $existing,
            \sprintf(
                'Not migrating: %s already exist(s) in schema "%s"; this migration only creates new tables. '
                .'Rename the existing relation (see docs/architecture/sessions-and-cache.md, "Existing tables"), then migrate again.',
                implode(', ', array_map(self::text(...), $existing)),
                self::text($this->connection->fetchOne('SELECT current_schema()::text')),
            ),
        );

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

    private static function text(mixed $value): string
    {
        return \is_string($value) ? $value : get_debug_type($value);
    }
}
