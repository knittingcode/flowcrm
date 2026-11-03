<?php

declare(strict_types=1);

namespace App\Identity\Application;

use App\Audit\Api\Actor;
use App\Audit\Api\AuditRecord;
use App\Audit\Api\AuditTrail;
use App\Identity\Domain\PasswordPolicy;
use App\Identity\Domain\UserRepository;
use App\Shared\Application\Transaction;
use Psr\Clock\ClockInterface;
use Symfony\Component\Uid\Uuid;

/** FCRM-002 REQ-006: a logged-in user changes their own password; the current one is required. */
final readonly class ChangeOwnPassword
{
    public function __construct(
        private UserRepository $users,
        private PasswordHasher $hasher,
        private Transaction $transaction,
        private AuditTrail $audit,
        private ClockInterface $clock,
    ) {
    }

    /**
     * @throws PasswordRejected
     * @throws WrongCurrentPassword
     * @throws UserNotFound
     */
    public function __invoke(Uuid $userId, #[\SensitiveParameter] string $currentPassword, #[\SensitiveParameter] string $newPassword, ?Uuid $requestId): void
    {
        $user = $this->users->ofId($userId) ?? throw new UserNotFound();
        $violations = PasswordPolicy::violations($newPassword);
        if ([] !== $violations) {
            throw new PasswordRejected($violations);
        }
        if (!$this->hasher->verify($user->passwordHash(), $currentPassword)) {
            throw new WrongCurrentPassword();
        }
        $hash = $this->hasher->hash($newPassword);

        $this->transaction->run(function () use ($user, $hash, $requestId): void {
            $user->changePassword($hash, $this->clock->now());
            $this->audit->record(new AuditRecord('auth.password_changed', 'user', $user->id(), Actor::user($user->id()), requestId: $requestId));
        });
    }
}
