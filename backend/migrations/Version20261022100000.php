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
 * This migration owns both tables. A table that already exists (for example
 * one an earlier build let the cache adapter create) is adopted only when
 * it matches the definition below column by column; otherwise the migration
 * aborts and changes nothing, and the table has to be inspected by hand
 * (docs/architecture/sessions-and-cache.md). Nothing is dropped or altered.
 */
final class Version20261022100000 extends AbstractMigration
{
    /** Column => [data_type, character_maximum_length, is_nullable], in order. */
    private const SESSIONS = [
        'sess_id' => ['character varying', 128, 'NO'],
        'sess_data' => ['bytea', null, 'NO'],
        'sess_lifetime' => ['integer', null, 'NO'],
        'sess_time' => ['integer', null, 'NO'],
    ];
    private const CACHE_ITEMS = [
        'item_id' => ['character varying', 255, 'NO'],
        'item_data' => ['bytea', null, 'NO'],
        'item_lifetime' => ['integer', null, 'YES'],
        'item_time' => ['integer', null, 'NO'],
    ];

    public function getDescription(): string
    {
        return 'Create the sessions and cache_items tables used by Symfony (FCRM-FND-008).';
    }

    public function up(Schema $schema): void
    {
        if ($this->adopt('sessions', self::SESSIONS, 'sess_id')) {
            $index = $this->connection->fetchOne(
                "SELECT indexdef FROM pg_indexes WHERE schemaname = current_schema() AND tablename = 'sessions' AND indexname = 'sess_lifetime_idx'",
            );
            $this->abortIf(
                false !== $index && !str_ends_with(self::text($index), 'USING btree (sess_lifetime)'),
                'sessions has an index sess_lifetime_idx that is not on (sess_lifetime); inspect it before migrating.',
            );
            if (false === $index) {
                $this->addSql('CREATE INDEX sess_lifetime_idx ON sessions (sess_lifetime)');
            }
        } else {
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
        }

        if (!$this->adopt('cache_items', self::CACHE_ITEMS, 'item_id')) {
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
    }

    public function down(Schema $schema): void
    {
        $this->addSql('DROP TABLE cache_items');
        $this->addSql('DROP TABLE sessions');
    }

    /**
     * False if the table does not exist; true if it exists and matches the
     * expected columns and primary key exactly. Aborts the migration if it
     * exists but differs.
     *
     * @param array<string, array{string, int|null, string}> $columns
     */
    private function adopt(string $table, array $columns, string $primaryKey): bool
    {
        $found = $this->connection->fetchAllAssociative(
            'SELECT column_name, data_type, character_maximum_length, is_nullable, column_default
               FROM information_schema.columns
              WHERE table_schema = current_schema() AND table_name = ?
              ORDER BY ordinal_position',
            [$table],
        );
        if ([] === $found) {
            return false;
        }

        $actual = [];
        foreach ($found as $column) {
            $length = $column['character_maximum_length'];
            $actual[self::text($column['column_name'])] = [
                self::text($column['data_type']),
                null === $length ? null : (int) self::text($length),
                self::text($column['is_nullable']),
                $column['column_default'],
            ];
        }
        $expected = array_map(static fn (array $c): array => [...$c, null], $columns);
        $keys = $this->connection->fetchFirstColumn(
            'SELECT a.attname
               FROM pg_index i JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY (i.indkey)
              WHERE i.indrelid = to_regclass(?) AND i.indisprimary',
            [$table],
        );

        $this->abortIf(
            $actual !== $expected || $keys !== [$primaryKey],
            \sprintf('Table %s already exists with a different definition; it was not changed. Inspect it (and back it up) before migrating.', $table),
        );
        $this->write(\sprintf('Adopting the existing %s table: it matches the expected definition.', $table));

        return true;
    }

    private static function text(mixed $value): string
    {
        if (!\is_scalar($value)) {
            throw new \UnexpectedValueException('unexpected catalog value: '.get_debug_type($value));
        }

        return (string) $value;
    }
}
