<?php

declare(strict_types=1);

namespace App\Identity\Application;

use App\Audit\Api\Actor;
use App\Audit\Api\AuditRecord;
use App\Audit\Api\AuditTrail;
use App\Identity\Domain\PasswordPolicy;
use App\Identity\Domain\User;
use App\Identity\Domain\UserRepository;
use App\Shared\Application\Transaction;
use Psr\Clock\ClockInterface;
use Symfony\Component\Uid\Uuid;

/**
 * The platform operator's user administration (console only; FCRM-002:
 * no public registration). Every change is audited with the operator as
 * the actor, in the same transaction.
 */
final readonly class ManageUsers
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
     * @throws EmailTaken
     * @throws \InvalidArgumentException for an invalid e-mail address or display name
     */
    public function create(string $email, string $displayName, #[\SensitiveParameter] string $password): Uuid
    {
        self::checkPolicy($password);
        if (null !== $this->users->ofEmail($email)) {
            throw new EmailTaken();
        }
        $user = new User(Uuid::v7(), $email, $this->hasher->hash($password), $displayName, $this->clock->now());

        $this->transaction->run(function () use ($user): void {
            $this->users->add($user);
            $this->audit->record(new AuditRecord('user.created', 'user', $user->id(), Actor::operator()));
        });

        return $user->id();
    }

    /**
     * Sets a new password; every session of the user ends.
     *
     * @throws PasswordRejected
     * @throws UserNotFound
     */
    public function resetPassword(string $email, #[\SensitiveParameter] string $password): void
    {
        self::checkPolicy($password);
        $user = $this->users->ofEmail($email) ?? throw new UserNotFound();
        $hash = $this->hasher->hash($password);

        $this->transaction->run(function () use ($user, $hash): void {
            $user->changePassword($hash, $this->clock->now());
            $this->audit->record(new AuditRecord('user.password_reset', 'user', $user->id(), Actor::operator()));
        });
    }

    /**
     * Every session of the user ends on its next request, and login fails.
     *
     * @throws UserNotFound
     */
    public function disable(string $email): void
    {
        $user = $this->users->ofEmail($email) ?? throw new UserNotFound();

        $this->transaction->run(function () use ($user): void {
            $user->disable($this->clock->now());
            $this->audit->record(new AuditRecord('user.disabled', 'user', $user->id(), Actor::operator()));
        });
    }

    /** @throws UserNotFound */
    public function enable(string $email): void
    {
        $user = $this->users->ofEmail($email) ?? throw new UserNotFound();

        $this->transaction->run(function () use ($user): void {
            $user->enable();
            $this->audit->record(new AuditRecord('user.enabled', 'user', $user->id(), Actor::operator()));
        });
    }

    private static function checkPolicy(#[\SensitiveParameter] string $password): void
    {
        $violations = PasswordPolicy::violations($password);
        if ([] !== $violations) {
            throw new PasswordRejected($violations);
        }
    }
}
