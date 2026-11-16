<?php

declare(strict_types=1);

namespace App\Tests\Integration\Database;

use App\CRM\Domain\Account;
use App\CRM\Domain\AccountDetails;
use App\Tests\Support\TypedValues;
use Doctrine\DBAL\Connection;
use Doctrine\DBAL\Exception\DriverException;
use Doctrine\ORM\EntityManagerInterface;
use Symfony\Bundle\FrameworkBundle\Test\KernelTestCase;
use Symfony\Component\Uid\Uuid;

/**
 * The accounts table as PostgreSQL enforces it, with raw SQL as the runtime
 * role flowcrm_app, and its ORM mapping. Every test runs in a transaction
 * that is rolled back; each expected violation runs in its own savepoint.
 */
final class AccountSchemaTest extends KernelTestCase
{
    use TypedValues;

    private Connection $db;

    protected function setUp(): void
    {
        $db = self::getContainer()->get('doctrine.dbal.default_connection');
        self::assertInstanceOf(Connection::class, $db);
        $this->db = $db;
        $this->db->beginTransaction();
    }

    protected function tearDown(): void
    {
        $this->db->rollBack();
        parent::tearDown();
    }

    public function testAnAccountBelongsToAnExistingOrganization(): void
    {
        $this->assertViolation('23503', 'accounts_organization_fkey', fn () => $this->account(Uuid::v7()->toRfc4122(), 'Acme'));
        $this->assertViolation('23502', 'organization_id', fn () => $this->db->insert('accounts', ['id' => Uuid::v7()->toRfc4122(), 'name' => 'Acme', 'created_at' => '2026-11-16T00:00:00Z', 'updated_at' => '2026-11-16T00:00:00Z']));
        $this->account($this->organization(), 'Acme');
    }

    public function testTheNameAndTheLengthsAreChecked(): void
    {
        $org = $this->organization();

        $this->assertViolation('23514', 'accounts_name_check', fn () => $this->account($org, '   '));
        $this->assertViolation('23514', 'accounts_name_check', fn () => $this->account($org, str_repeat('a', 201)));
        $this->assertViolation('23514', 'accounts_website_length_check', fn () => $this->account($org, 'Acme', ['website' => str_repeat('a', 2049)]));
        $this->assertViolation('23514', 'accounts_email_length_check', fn () => $this->account($org, 'Acme', ['email' => str_repeat('a', 255)]));
        $this->assertViolation('23514', 'accounts_phone_length_check', fn () => $this->account($org, 'Acme', ['phone' => str_repeat('1', 51)]));
        $this->account($org, str_repeat('ż', 200), ['website' => str_repeat('a', 2048), 'email' => str_repeat('a', 254), 'phone' => str_repeat('1', 50)]);
    }

    /** Child tables will reference (organization_id, id): the pair is unique, and the same name may exist twice. */
    public function testTheTenantKeyIsUnique(): void
    {
        $org = $this->organization();
        $id = $this->account($org, 'Acme');
        $this->account($org, 'Acme');

        $this->assertViolation('23505', 'accounts_pkey', fn () => $this->db->insert('accounts', ['id' => $id, 'organization_id' => $this->organization(), 'name' => 'Other', 'created_at' => '2026-11-16T00:00:00Z', 'updated_at' => '2026-11-16T00:00:00Z']));
        self::assertSame(1, self::int($this->db->fetchOne("SELECT count(*) FROM pg_constraint WHERE conname = 'accounts_organization_id_key' AND contype = 'u'")));
    }

    /** The runtime role reads, inserts and updates accounts; it cannot delete or truncate them (ADR-018). */
    public function testTheRuntimeRoleCannotDeleteAccounts(): void
    {
        $id = $this->account($this->organization(), 'Acme');
        $this->db->executeStatement('UPDATE accounts SET archived_at = now() WHERE id = ?', [$id]);

        $this->assertViolation('42501', 'permission denied', fn () => $this->db->executeStatement('DELETE FROM accounts WHERE id = ?', [$id]));
        $this->assertViolation('42501', 'permission denied', fn () => $this->db->executeStatement('TRUNCATE accounts'));
        self::assertSame(1, self::int($this->db->fetchOne('SELECT count(*) FROM accounts WHERE id = ?', [$id])));
    }

    public function testTheEntityIsWrittenAndReadBackUnchanged(): void
    {
        $em = self::getContainer()->get('doctrine.orm.entity_manager');
        self::assertInstanceOf(EntityManagerInterface::class, $em);
        $at = new \DateTimeImmutable('2026-11-16T08:15:30+00:00');
        $account = new Account(Uuid::v7(), Uuid::fromString($this->organization()), AccountDetails::of('Acme', 'https://acme.example.test', 'biuro@acme.example.test', '+48 22 123 45 67'), $at);
        $em->persist($account);
        $em->flush();
        $account->archive($at->modify('+1 day'));
        $em->flush();
        $em->clear();

        $loaded = $em->find(Account::class, $account->id());
        self::assertInstanceOf(Account::class, $loaded);
        self::assertTrue($account->organizationId()->equals($loaded->organizationId()));
        self::assertSame(['Acme', 'https://acme.example.test', 'biuro@acme.example.test', '+48 22 123 45 67'], [$loaded->name(), $loaded->website(), $loaded->email(), $loaded->phone()]);
        self::assertEquals($at, $loaded->createdAt());
        self::assertEquals($at->modify('+1 day'), $loaded->updatedAt());
        self::assertEquals($at->modify('+1 day'), $loaded->archivedAt());
        $em->clear();
    }

    /** @param callable(): mixed $statement */
    private function assertViolation(string $sqlState, string $detail, callable $statement): void
    {
        $this->db->createSavepoint('expected_violation');
        try {
            $statement();
            self::fail(\sprintf('Expected SQLSTATE %s (%s), but the statement succeeded.', $sqlState, $detail));
        } catch (DriverException $e) {
            self::assertSame($sqlState, $e->getSQLState(), $e->getMessage());
            self::assertStringContainsString($detail, $e->getMessage());
        } finally {
            $this->db->rollbackSavepoint('expected_violation');
        }
    }

    private function organization(): string
    {
        $id = Uuid::v7()->toRfc4122();
        $this->db->insert('organizations', ['id' => $id, 'name' => 'Org '.$id, 'currency' => 'EUR', 'timezone' => 'Europe/Warsaw', 'created_at' => '2026-11-16T00:00:00Z']);

        return $id;
    }

    /** @param array<string, string> $more */
    private function account(string $org, string $name, array $more = []): string
    {
        $id = Uuid::v7()->toRfc4122();
        $this->db->insert('accounts', ['id' => $id, 'organization_id' => $org, 'name' => $name, 'created_at' => '2026-11-16T00:00:00Z', 'updated_at' => '2026-11-16T00:00:00Z'] + $more);

        return $id;
    }
}
