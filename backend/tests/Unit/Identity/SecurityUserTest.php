<?php

declare(strict_types=1);

namespace App\Tests\Unit\Identity;

use App\Identity\Domain\User;
use App\Identity\Infrastructure\Security\SecurityUser;
use PHPUnit\Framework\TestCase;
use Symfony\Component\Uid\Uuid;

final class SecurityUserTest extends TestCase
{
    private const HASH = '$argon2id$v=19$m=10,t=3,p=1$c2FsdHNhbHQ$aGFzaGhhc2g';

    public function testTheSessionFormHasNeitherTheHashNorTheEmail(): void
    {
        $user = $this->user();
        $stored = serialize(SecurityUser::fromUser($user, 1_761_200_000));

        self::assertStringNotContainsString(self::HASH, $stored);
        self::assertStringNotContainsString('$argon2', $stored);
        self::assertStringNotContainsString($user->email(), $stored);
        self::assertStringContainsString($user->id()->toRfc4122(), $stored);

        $restored = unserialize($stored);
        self::assertInstanceOf(SecurityUser::class, $restored);
        self::assertNull($restored->getPassword());
        self::assertSame(1_761_200_000, $restored->authenticatedAt());
    }

    public function testOnlyRoleUser(): void
    {
        self::assertSame(['ROLE_USER'], SecurityUser::fromUser($this->user(), 0)->getRoles());
    }

    public function testTheSessionStaysOnlyWhileNothingChanged(): void
    {
        $user = $this->user();
        $session = unserialize(serialize(SecurityUser::fromUser($user, 100)));
        self::assertInstanceOf(SecurityUser::class, $session);

        self::assertTrue($session->isEqualTo(SecurityUser::fromUser($user, 100)), 'unchanged');
        self::assertFalse($session->isEqualTo(SecurityUser::fromUser($user, 100, expired: true)), 'absolute lifetime over');
        self::assertFalse($session->isEqualTo(SecurityUser::fromUser($this->user(), 100)), 'another user');

        $user->rehashPassword(self::HASH.'x');
        self::assertFalse($session->isEqualTo(SecurityUser::fromUser($user, 100)), 'another hash');

        $changed = $this->user();
        $before = unserialize(serialize(SecurityUser::fromUser($changed, 100)));
        self::assertInstanceOf(SecurityUser::class, $before);
        $changed->changePassword(self::HASH, new \DateTimeImmutable('2026-10-23 10:00:00'));
        self::assertFalse($before->isEqualTo(SecurityUser::fromUser($changed, 100)), 'password changed (same hash value)');

        $disabled = $this->user();
        $active = unserialize(serialize(SecurityUser::fromUser($disabled, 100)));
        self::assertInstanceOf(SecurityUser::class, $active);
        $disabled->disable(new \DateTimeImmutable());
        self::assertFalse($active->isEqualTo(SecurityUser::fromUser($disabled, 100)), 'disabled');
    }

    public function testARehashDuringTheLoginKeepsThatSession(): void
    {
        $user = $this->user();
        $loggingIn = SecurityUser::fromUser($user, 100);
        $user->rehashPassword('$argon2id$v=19$m=19456,t=3,p=1$bmV3$bmV3');
        $loggingIn->rehashed($user->passwordHash(), $user->passwordChangedAt());
        $session = unserialize(serialize($loggingIn));
        self::assertInstanceOf(SecurityUser::class, $session);

        self::assertTrue($session->isEqualTo(SecurityUser::fromUser($user, 100)));
    }

    private function user(): User
    {
        return new User(Uuid::v7(), 'unit-'.bin2hex(random_bytes(3)).'@example.test', self::HASH, 'Unit', new \DateTimeImmutable('2026-10-23'));
    }
}
