<?php

declare(strict_types=1);

namespace App\CRM\Application;

use App\Audit\Api\Actor;
use App\Audit\Api\AuditRecord;
use App\Audit\Api\AuditTrail;
use App\CRM\Domain\Account;
use App\CRM\Domain\AccountArchived;
use App\CRM\Domain\AccountDetails;
use App\CRM\Domain\AccountRepository;
use App\Organizations\Api\TenantContext;
use App\Shared\Application\Transaction;
use Psr\Clock\ClockInterface;
use Symfony\Component\Uid\Uuid;

/**
 * Creating, editing and archiving accounts. The organization is always the
 * one of the TenantContext that TenantGuard resolved from the route; an
 * account is loaded together with it, so an ID of another organization is
 * not found. Every change is audited in the same transaction; the audit
 * event names the changed fields, never their values.
 */
final readonly class ManageAccounts
{
    public function __construct(
        private AccountRepository $accounts,
        private Transaction $transaction,
        private AuditTrail $audit,
        private ClockInterface $clock,
    ) {
    }

    public function create(TenantContext $tenant, AccountDetails $details, ?Uuid $requestId): Uuid
    {
        $account = new Account(Uuid::v7(), $tenant->organizationId, $details, $this->clock->now());

        $this->transaction->run(function () use ($account, $tenant, $requestId): void {
            $this->accounts->add($account);
            $this->audit->record(new AuditRecord('account.created', 'account', $account->id(), self::actor($tenant), $tenant->organizationId, requestId: $requestId));
        });

        return $account->id();
    }

    /**
     * @throws AccountNotFound
     * @throws AccountArchived
     */
    public function update(TenantContext $tenant, Uuid $accountId, AccountDetails $details, ?Uuid $requestId): void
    {
        $this->transaction->run(function () use ($tenant, $accountId, $details, $requestId): void {
            $account = $this->accounts->ofId($tenant->organizationId, $accountId) ?? throw new AccountNotFound();
            $changed = $account->change($details, $this->clock->now());
            if ([] !== $changed) {
                $this->audit->record(new AuditRecord('account.updated', 'account', $account->id(), self::actor($tenant), $tenant->organizationId, ['fields' => $changed], $requestId));
            }
        });
    }

    /**
     * Archiving an archived account changes nothing and is not an error.
     *
     * @throws AccountNotFound
     */
    public function archive(TenantContext $tenant, Uuid $accountId, ?Uuid $requestId): void
    {
        $this->transaction->run(function () use ($tenant, $accountId, $requestId): void {
            $account = $this->accounts->ofId($tenant->organizationId, $accountId) ?? throw new AccountNotFound();
            if ($account->archive($this->clock->now())) {
                $this->audit->record(new AuditRecord('account.archived', 'account', $account->id(), self::actor($tenant), $tenant->organizationId, requestId: $requestId));
            }
        });
    }

    private static function actor(TenantContext $tenant): Actor
    {
        return Actor::user($tenant->userId, $tenant->role);
    }
}
