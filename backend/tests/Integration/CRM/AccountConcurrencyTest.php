<?php

declare(strict_types=1);

namespace App\Tests\Integration\CRM;

use App\CRM\Application\ManageAccounts;
use App\CRM\Domain\AccountArchived;
use App\CRM\Domain\AccountDetails;
use App\Organizations\Api\TenantContext;
use App\Tests\Support\Session\SeparateConnection;
use App\Tests\Support\TypedValues;
use Doctrine\DBAL\Connection;
use Doctrine\DBAL\Exception\DriverException;
use Symfony\Bundle\FrameworkBundle\Test\KernelTestCase;
use Symfony\Component\Uid\Uuid;

/**
 * Two requests that change the same account run one after the other: a write
 * loads the account with a row lock, so it cannot change an account that
 * another transaction is archiving at the same time. The other transaction
 * is a second connection of the runtime role, as another PHP-FPM worker
 * would have.
 */
final class AccountConcurrencyTest extends KernelTestCase
{
    use TypedValues;

    private Connection $db;
    private ManageAccounts $manage;
    private TenantContext $tenant;
    private Uuid $account;

    protected function setUp(): void
    {
        $db = self::getContainer()->get('doctrine.dbal.default_connection');
        $manage = self::getContainer()->get(ManageAccounts::class);
        self::assertInstanceOf(Connection::class, $db);
        self::assertInstanceOf(ManageAccounts::class, $manage);
        $this->db = $db;
        $this->manage = $manage;

        $organization = Uuid::v7();
        $this->account = Uuid::v7();
        $this->db->insert('organizations', ['id' => $organization->toRfc4122(), 'name' => 'Concurrency '.bin2hex(random_bytes(3)), 'currency' => 'EUR', 'timezone' => 'Europe/Warsaw', 'created_at' => '2026-11-16 08:00:00+00']);
        $this->db->insert('accounts', ['id' => $this->account->toRfc4122(), 'organization_id' => $organization->toRfc4122(), 'name' => 'Acme', 'created_at' => '2026-11-16 08:00:00+00', 'updated_at' => '2026-11-16 08:00:00+00']);
        $this->tenant = new TenantContext($organization, Uuid::v7(), Uuid::v7(), 'ADMIN');
    }

    /**
     * While another transaction holds the account, a write waits for it even
     * when it would change nothing (unchanged details issue no UPDATE): the
     * account is locked when it is loaded, not only when it is written.
     */
    public function testAWriteWaitsForAnotherTransactionOnTheSameAccount(): void
    {
        $other = SeparateConnection::open();
        $other->beginTransaction();
        $other->prepare('SELECT 1 FROM accounts WHERE id = ? FOR UPDATE')->execute([$this->account->toRfc4122()]);
        $this->db->executeStatement("SET lock_timeout = '300ms'");

        $failure = null;
        try {
            $this->manage->update($this->tenant, $this->account, AccountDetails::of('Acme'), null);
        } catch (\Throwable $e) {
            $failure = $e;
        } finally {
            $other->rollBack();
            $this->db->executeStatement('RESET lock_timeout');
        }
        self::assertInstanceOf(DriverException::class, $failure, 'The write did not wait for the lock of the other transaction.');
        self::assertSame('55P03', $failure->getSQLState(), 'lock_not_available: '.$failure->getMessage());
        self::assertSame('Acme', self::string($this->db->fetchOne('SELECT name FROM accounts WHERE id = ?', [$this->account->toRfc4122()])));
    }

    /** What the write then sees is the committed state: an account archived meanwhile is not changed. */
    public function testAWriteAfterAConcurrentArchiveIsRefused(): void
    {
        $other = SeparateConnection::open();
        $other->prepare('UPDATE accounts SET archived_at = now(), updated_at = now() WHERE id = ?')->execute([$this->account->toRfc4122()]);

        try {
            $this->manage->update($this->tenant, $this->account, AccountDetails::of('Renamed'), null);
            self::fail('An archived account was changed.');
        } catch (AccountArchived) {
            self::assertSame('Acme', self::string($this->db->fetchOne('SELECT name FROM accounts WHERE id = ?', [$this->account->toRfc4122()])));
            self::assertSame(0, self::int($this->db->fetchOne("SELECT count(*) FROM audit_events WHERE entity_id = ? AND action = 'account.updated'", [$this->account->toRfc4122()])));
        }
    }
}
