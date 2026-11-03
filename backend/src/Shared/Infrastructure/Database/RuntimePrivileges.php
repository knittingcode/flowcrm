<?php

declare(strict_types=1);

namespace App\Shared\Infrastructure\Database;

use Doctrine\DBAL\Connection;
use Symfony\Component\DependencyInjection\Attribute\Autowire;
use Symfony\Component\Yaml\Yaml;

/**
 * Compares the database with the runtime privilege manifest
 * (config/database/runtime-privileges.yaml, ADR-018) and lists every
 * difference. It only reads catalogs any role may read, so the runtime role
 * can check its own privileges.
 *
 * Checked: the attributes and memberships of flowcrm_owner and flowcrm_app;
 * no PUBLIC privileges on the database, schema public, its objects and
 * functions; flowcrm_app has CONNECT and schema USAGE only; every object of
 * schema public is owned by flowcrm_owner and listed in the manifest, and
 * flowcrm_app holds exactly the listed privileges (no grant option, no
 * column privileges); default privileges give new objects no access.
 *
 * Beyond schema public: flowcrm_app may not connect to any other database
 * (postgres, template1 included), use or create in any other non-system
 * schema, reach any object there, own anything, or hold parameter,
 * tablespace or foreign-server privileges; no role's default privileges may
 * give it or PUBLIC anything. System schemas (pg_*, information_schema) keep
 * PostgreSQL's built-in defaults and are not inspected.
 */
final readonly class RuntimePrivileges
{
    public const OWNER = 'flowcrm_owner';
    public const RUNTIME = 'flowcrm_app';

    public function __construct(
        private Connection $connection,
        #[Autowire('%kernel.project_dir%/config/database/runtime-privileges.yaml')]
        private string $manifest,
    ) {
    }

    /**
     * Reads the live catalog, so two calls may differ.
     *
     * @return list<string>
     *
     * @phpstan-impure
     */
    public function violations(): array
    {
        $manifest = $this->manifest();
        $violations = [
            ...$this->roles(),
            ...$this->databaseAndSchema(),
            ...$this->objects($manifest['tables'], $manifest['sequences']),
            ...$this->functions($manifest['functions']),
            ...$this->defaults(),
            ...$this->beyondPublic(),
        ];
        sort($violations);

        return $violations;
    }

    /** The role this connection uses, and whether it is a superuser. */
    public function currentRole(): string
    {
        $row = $this->connection->fetchAssociative('SELECT current_user AS name, rolsuper FROM pg_roles WHERE rolname = current_user');

        return \is_array($row) && true !== $row['rolsuper'] ? self::text($row['name']) : 'superuser';
    }

    /** @return list<string> */
    private function roles(): array
    {
        $violations = [];
        $rows = $this->connection->fetchAllAssociativeIndexed(
            'SELECT rolname, rolsuper, rolinherit, rolcreaterole, rolcreatedb, rolcanlogin, rolreplication, rolbypassrls FROM pg_roles WHERE rolname IN (?, ?)',
            [self::OWNER, self::RUNTIME],
        );
        foreach ([self::OWNER, self::RUNTIME] as $role) {
            $r = $rows[$role] ?? null;
            if (null === $r) {
                $violations[] = "role {$role} does not exist";
                continue;
            }
            foreach (['rolsuper', 'rolcreaterole', 'rolcreatedb', 'rolreplication', 'rolbypassrls'] as $attribute) {
                if (true === $r[$attribute]) {
                    $violations[] = "role {$role} has {$attribute}";
                }
            }
            if (true !== $r['rolcanlogin']) {
                $violations[] = "role {$role} cannot log in";
            }
        }
        if (true === ($rows[self::RUNTIME]['rolinherit'] ?? false)) {
            $violations[] = 'role '.self::RUNTIME.' inherits privileges (expected NOINHERIT)';
        }
        foreach ($this->connection->fetchAllAssociative(
            'SELECT r.rolname AS role, m.rolname AS member FROM pg_auth_members a
               JOIN pg_roles r ON r.oid = a.roleid JOIN pg_roles m ON m.oid = a.member
              WHERE m.rolname IN (?, ?) OR r.rolname IN (?, ?)',
            [self::OWNER, self::RUNTIME, self::OWNER, self::RUNTIME],
        ) as $m) {
            $violations[] = \sprintf('role %s is a member of %s', self::text($m['member']), self::text($m['role']));
        }

        return $violations;
    }

    /** @return list<string> */
    private function databaseAndSchema(): array
    {
        $violations = [];
        $row = $this->connection->fetchAssociative(
            "SELECT d.datacl IS NULL AS default_acl,
                    (SELECT count(*) FROM aclexplode(d.datacl) a WHERE a.grantee = 0) AS public_grants,
                    has_database_privilege(?, d.datname, 'CONNECT') AS connect,
                    has_database_privilege(?, d.datname, 'CREATE') AS create,
                    has_database_privilege(?, d.datname, 'TEMPORARY') AS temporary,
                    pg_get_userbyid(n.nspowner) AS schema_owner,
                    (SELECT count(*) FROM aclexplode(n.nspacl) a WHERE a.grantee = 0) AS schema_public_grants,
                    has_schema_privilege(?, n.oid, 'USAGE') AS usage,
                    has_schema_privilege(?, n.oid, 'CREATE') AS schema_create
               FROM pg_database d, pg_namespace n
              WHERE d.datname = current_database() AND n.nspname = 'public'",
            array_fill(0, 5, self::RUNTIME),
        );
        if (!\is_array($row)) {
            return ['database or schema public not found'];
        }
        if (true === $row['default_acl'] || 0 !== self::int($row['public_grants'])) {
            $violations[] = 'PUBLIC has privileges on the database';
        }
        if (true !== $row['connect']) {
            $violations[] = self::RUNTIME.' cannot connect to the database';
        }
        if (true === $row['create'] || true === $row['temporary']) {
            $violations[] = self::RUNTIME.' may create schemas or temporary tables in the database';
        }
        if (self::OWNER !== $row['schema_owner']) {
            $violations[] = \sprintf('schema public is owned by %s, not %s', self::text($row['schema_owner']), self::OWNER);
        }
        if (0 !== self::int($row['schema_public_grants'])) {
            $violations[] = 'PUBLIC has privileges on schema public';
        }
        if (true !== $row['usage']) {
            $violations[] = self::RUNTIME.' has no USAGE on schema public';
        }
        if (true === $row['schema_create']) {
            $violations[] = self::RUNTIME.' may create objects in schema public';
        }

        return $violations;
    }

    /**
     * @param array<string, list<string>> $tables
     * @param array<string, list<string>> $sequences
     *
     * @return list<string>
     */
    private function objects(array $tables, array $sequences): array
    {
        $violations = [];
        $seen = [];
        foreach ($this->connection->fetchAllAssociative(
            "SELECT c.relname, c.relkind::text AS kind, pg_get_userbyid(c.relowner) AS owner,
                    coalesce((SELECT string_agg(a.privilege_type, ',' ORDER BY a.privilege_type) FROM aclexplode(c.relacl) a
                               WHERE a.grantee = (SELECT oid FROM pg_roles WHERE rolname = ?)), '') AS runtime,
                    (SELECT count(*) FROM aclexplode(c.relacl) a
                      WHERE a.grantee = 0 OR (a.is_grantable AND a.grantee = (SELECT oid FROM pg_roles WHERE rolname = ?))) AS unsafe,
                    (SELECT count(*) FROM pg_attribute t, aclexplode(t.attacl) a
                      WHERE t.attrelid = c.oid AND (a.grantee = 0 OR a.grantee = (SELECT oid FROM pg_roles WHERE rolname = ?))) AS column_grants
               FROM pg_class c
              WHERE c.relnamespace = 'public'::regnamespace AND c.relkind IN ('r', 'p', 'v', 'm', 'f', 'S')
              ORDER BY c.relname",
            [self::RUNTIME, self::RUNTIME, self::RUNTIME],
        ) as $o) {
            $name = self::text($o['relname']);
            $isSequence = 'S' === $o['kind'];
            $list = $isSequence ? $sequences : $tables;
            $what = $isSequence ? 'sequence' : 'table';
            $seen[$what][$name] = true;
            if (self::OWNER !== $o['owner']) {
                $violations[] = \sprintf('%s %s is owned by %s, not %s', $what, $name, self::text($o['owner']), self::OWNER);
            }
            if (0 !== self::int($o['unsafe'])) {
                $violations[] = "{$what} {$name} grants privileges to PUBLIC or with grant option";
            }
            if (0 !== self::int($o['column_grants'])) {
                $violations[] = "{$what} {$name} has column privileges for PUBLIC or ".self::RUNTIME;
            }
            if (!\array_key_exists($name, $list)) {
                $violations[] = "{$what} {$name} is not listed in the runtime privilege manifest";
                continue;
            }
            $expected = $list[$name];
            sort($expected);
            $actual = '' === $o['runtime'] ? [] : explode(',', self::text($o['runtime']));
            if ($expected !== $actual) {
                $violations[] = \sprintf('%s %s: %s has [%s], the manifest lists [%s]', $what, $name, self::RUNTIME, implode(', ', $actual), implode(', ', $expected));
            }
        }
        foreach (['table' => $tables, 'sequence' => $sequences] as $what => $list) {
            foreach (array_keys($list) as $name) {
                if (!isset($seen[$what][$name])) {
                    $violations[] = "{$what} {$name} is listed in the manifest but does not exist";
                }
            }
        }

        return $violations;
    }

    /**
     * @param array<string, list<string>> $allowed
     *
     * @return list<string>
     */
    private function functions(array $allowed): array
    {
        $violations = [];
        foreach ($this->connection->fetchAllAssociative(
            "SELECT p.proname, pg_get_userbyid(p.proowner) AS owner, p.proacl IS NULL AS default_acl,
                    (SELECT count(*) FROM aclexplode(p.proacl) a
                      WHERE a.grantee = 0 OR a.grantee = (SELECT oid FROM pg_roles WHERE rolname = ?)) AS grants
               FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace ORDER BY p.proname",
            [self::RUNTIME],
        ) as $f) {
            $name = self::text($f['proname']);
            if (self::OWNER !== $f['owner']) {
                $violations[] = \sprintf('function %s is owned by %s, not %s', $name, self::text($f['owner']), self::OWNER);
            }
            if (!\array_key_exists($name, $allowed) && (true === $f['default_acl'] || 0 !== self::int($f['grants']))) {
                $violations[] = "function {$name} is executable by PUBLIC or ".self::RUNTIME;
            }
        }

        return $violations;
    }

    /** @return list<string> */
    private function defaults(): array
    {
        $violations = [];
        foreach ($this->connection->fetchAllAssociative(
            'SELECT DISTINCT pg_get_userbyid(d.defaclrole) AS role, d.defaclobjtype::text AS type FROM pg_default_acl d, aclexplode(d.defaclacl) a
              WHERE a.grantee = 0 OR a.grantee = (SELECT oid FROM pg_roles WHERE rolname = ?)
              ORDER BY 1, 2',
            [self::RUNTIME],
        ) as $d) {
            $violations[] = \sprintf('default privileges of %s give new %s to PUBLIC or %s', self::text($d['role']), ['r' => 'tables', 'S' => 'sequences', 'f' => 'functions', 'n' => 'schemas', 'T' => 'types', 'L' => 'large objects'][self::text($d['type'])] ?? 'objects', self::RUNTIME);
        }
        $revoked = $this->connection->fetchOne(
            "SELECT count(*) FROM pg_default_acl WHERE defaclrole = (SELECT oid FROM pg_roles WHERE rolname = ?) AND defaclobjtype = 'f' AND defaclnamespace = 0",
            [self::OWNER],
        );
        if (0 === self::int($revoked)) {
            $violations[] = 'new functions of '.self::OWNER.' would be executable by PUBLIC (default privileges not revoked)';
        }

        return $violations;
    }

    /**
     * Everything outside schema public that could give flowcrm_app access.
     *
     * @return list<string>
     */
    private function beyondPublic(): array
    {
        $runtime = '(SELECT oid FROM pg_roles WHERE rolname = :runtime)';
        $userSchemas = "n.nspname <> 'public' AND n.nspname <> 'information_schema' AND n.nspname !~ '^pg_'";
        $checks = [
            // Other databases, postgres and template1 included.
            "SELECT 'flowcrm_app may connect to or create objects in database ' || datname FROM pg_database
              WHERE datname <> current_database() AND datallowconn
                AND (has_database_privilege(:runtime, oid, 'CONNECT') OR has_database_privilege(:runtime, oid, 'TEMPORARY')
                     OR has_database_privilege(:runtime, oid, 'CREATE'))",
            // Other non-system schemas of this database.
            "SELECT 'schema ' || n.nspname || ' is usable by PUBLIC or flowcrm_app' FROM pg_namespace n
              WHERE {$userSchemas} AND (has_schema_privilege(:runtime, n.oid, 'USAGE') OR has_schema_privilege(:runtime, n.oid, 'CREATE')
                    OR EXISTS (SELECT FROM aclexplode(n.nspacl) a WHERE a.grantee = 0))",
            "SELECT 'relation ' || n.nspname || '.' || c.relname || ' grants privileges to PUBLIC or flowcrm_app' FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
              WHERE {$userSchemas} AND EXISTS (SELECT FROM aclexplode(c.relacl) a WHERE a.grantee = 0 OR a.grantee = {$runtime})",
            "SELECT 'function ' || n.nspname || '.' || p.proname || ' is executable by PUBLIC or flowcrm_app' FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
              WHERE {$userSchemas} AND (p.proacl IS NULL OR EXISTS (SELECT FROM aclexplode(p.proacl) a WHERE a.grantee = 0 OR a.grantee = {$runtime}))",
            // Ownership gives every privilege on the object.
            "SELECT 'flowcrm_app owns schema ' || nspname FROM pg_namespace WHERE nspowner = {$runtime}",
            "SELECT 'flowcrm_app owns relation ' || relnamespace::regnamespace::text || '.' || relname FROM pg_class WHERE relowner = {$runtime}",
            "SELECT 'flowcrm_app owns function ' || pronamespace::regnamespace::text || '.' || proname FROM pg_proc WHERE proowner = {$runtime}",
            // Cluster-wide privileges.
            "SELECT 'parameter ' || parname || ' grants privileges to PUBLIC or flowcrm_app' FROM pg_parameter_acl
              WHERE EXISTS (SELECT FROM aclexplode(paracl) a WHERE a.grantee = 0 OR a.grantee = {$runtime})",
            "SELECT 'tablespace ' || spcname || ' grants privileges to PUBLIC or flowcrm_app' FROM pg_tablespace
              WHERE EXISTS (SELECT FROM aclexplode(spcacl) a WHERE a.grantee = 0 OR a.grantee = {$runtime})",
            "SELECT 'foreign server ' || srvname || ' grants privileges to PUBLIC or flowcrm_app' FROM pg_foreign_server
              WHERE EXISTS (SELECT FROM aclexplode(srvacl) a WHERE a.grantee = 0 OR a.grantee = {$runtime})",
            "SELECT 'foreign-data wrapper ' || fdwname || ' grants privileges to PUBLIC or flowcrm_app' FROM pg_foreign_data_wrapper
              WHERE EXISTS (SELECT FROM aclexplode(fdwacl) a WHERE a.grantee = 0 OR a.grantee = {$runtime})",
        ];
        $violations = [];
        foreach ($checks as $sql) {
            foreach ($this->connection->fetchFirstColumn($sql.' ORDER BY 1', ['runtime' => self::RUNTIME]) as $violation) {
                $violations[] = self::text($violation);
            }
        }

        return $violations;
    }

    /** @return array{tables: array<string, list<string>>, sequences: array<string, list<string>>, functions: array<string, list<string>>} */
    private function manifest(): array
    {
        $data = Yaml::parseFile($this->manifest);
        if (!\is_array($data)) {
            throw new \UnexpectedValueException('The runtime privilege manifest is not a map.');
        }
        $sections = [];
        foreach (['tables', 'sequences', 'functions'] as $section) {
            $entries = $data[$section] ?? null;
            if (!\is_array($entries)) {
                throw new \UnexpectedValueException("The runtime privilege manifest has no {$section} map.");
            }
            $sections[$section] = [];
            foreach ($entries as $name => $privileges) {
                if (!\is_string($name) || !\is_array($privileges) || !array_is_list($privileges)) {
                    throw new \UnexpectedValueException("Invalid {$section} entry in the runtime privilege manifest.");
                }
                $sections[$section][$name] = array_map(self::text(...), $privileges);
            }
        }

        return $sections;
    }

    private static function text(mixed $value): string
    {
        if (!\is_string($value)) {
            throw new \UnexpectedValueException('Unexpected catalog value: '.get_debug_type($value));
        }

        return $value;
    }

    private static function int(mixed $value): int
    {
        if (!\is_int($value)) {
            throw new \UnexpectedValueException('Unexpected catalog value: '.get_debug_type($value));
        }

        return $value;
    }
}
