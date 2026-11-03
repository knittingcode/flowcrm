<?php

declare(strict_types=1);

namespace App\Tests\Unit\Identity;

use App\Identity\Domain\User;
use App\Identity\Domain\UserRepository;
use App\Identity\Infrastructure\Security\SecurityUser;
use App\Identity\Infrastructure\Security\UserProvider;
use App\Shared\Application\Transaction;
use PHPUnit\Framework\TestCase;
use Symfony\Component\Clock\MockClock;
use Symfony\Component\PasswordHasher\Hasher\PasswordHasherFactoryInterface;
use Symfony\Component\PasswordHasher\PasswordHasherInterface;
use Symfony\Component\Security\Core\Exception\UserNotFoundException;
use Symfony\Component\Uid\Uuid;

/**
 * Timing equality of the login (no account enumeration): an unknown address
 * costs one hash, like the password check of a known one, and the
 * exception names no address.
 */
final class UserProviderTest extends TestCase
{
    public function testAnUnknownAddressCostsOneHashAndNamesNoAddress(): void
    {
        $hasher = $this->createMock(PasswordHasherInterface::class);
        $hasher->expects(self::once())->method('hash')->willReturn('$argon2id$dummy');

        try {
            $this->provider(null, $hasher)->loadUserByIdentifier('unknown@example.test');
            self::fail('no exception');
        } catch (UserNotFoundException $e) {
            self::assertNull($e->getUserIdentifier());
            self::assertStringNotContainsString('unknown@example.test', $e->getMessage());
        }
    }

    public function testAKnownAddressCostsNothingHereTheCredentialCheckHashesOnce(): void
    {
        $hasher = $this->createMock(PasswordHasherInterface::class);
        $hasher->expects(self::never())->method('hash');

        $user = $this->provider($this->user(), $hasher)->loadUserByIdentifier('known@example.test');

        self::assertSame(1_761_210_000, $user->authenticatedAt());
    }

    public function testARefreshAfterTheAbsoluteLifetimeEndsTheSession(): void
    {
        $user = $this->user();
        $session = unserialize(serialize(SecurityUser::fromUser($user, 1_761_210_000 - 28_800)));
        self::assertInstanceOf(SecurityUser::class, $session);
        $inTime = unserialize(serialize(SecurityUser::fromUser($user, 1_761_210_000 - 28_799)));
        self::assertInstanceOf(SecurityUser::class, $inTime);
        $provider = $this->provider($user, $this->createStub(PasswordHasherInterface::class));

        self::assertFalse($session->isEqualTo($provider->refreshUser($session)));
        self::assertTrue($inTime->isEqualTo($provider->refreshUser($inTime)));
    }

    private function provider(?User $user, PasswordHasherInterface $hasher): UserProvider
    {
        $users = $this->createStub(UserRepository::class);
        $users->method('ofEmail')->willReturn($user);
        $users->method('ofId')->willReturn($user);
        $hashers = $this->createStub(PasswordHasherFactoryInterface::class);
        $hashers->method('getPasswordHasher')->willReturn($hasher);

        return new UserProvider($users, $hashers, $this->createStub(Transaction::class), new MockClock('@1761210000'), 28_800);
    }

    private function user(): User
    {
        return new User(Uuid::v7(), 'known@example.test', '$argon2id$hash', 'Known', new \DateTimeImmutable('2026-10-23'));
    }
}
