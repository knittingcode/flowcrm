<?php

declare(strict_types=1);

namespace App\Tests\Unit\Domain;

use App\Audit\Domain\ActorType;
use App\Audit\Domain\AuditEvent;
use App\Identity\Domain\User;
use App\Organizations\Domain\Currency;
use App\Organizations\Domain\Membership;
use App\Organizations\Domain\MembershipRole;
use App\Organizations\Domain\MembershipStatus;
use App\Organizations\Domain\Organization;
use App\Sales\Domain\PipelineStage;
use PHPUnit\Framework\Attributes\DataProvider;
use PHPUnit\Framework\TestCase;
use Symfony\Component\Uid\Uuid;

/**
 * The checks the entities make before the database does, and the ones the
 * database cannot make (IANA timezones).
 */
final class CoreEntityRulesTest extends TestCase
{
    /**
     * @return iterable<string, array{string}>
     */
    public static function invalidEmails(): iterable
    {
        yield 'empty' => [''];
        yield 'no at sign' => ['anna.example.com'];
        yield 'whitespace' => ['anna @example.com'];
        yield 'too long' => [str_repeat('a', 243).'@example.com'];
    }

    #[DataProvider('invalidEmails')]
    public function testAUserNeedsAValidEmailAddress(string $email): void
    {
        $this->expectException(\InvalidArgumentException::class);
        new User(Uuid::v7(), $email, 'hash', 'Anna', new \DateTimeImmutable());
    }

    public function testTheLongestEmailAddressIsAccepted(): void
    {
        self::assertSame(254, \strlen(new User(Uuid::v7(), str_repeat('a', 242).'@example.com', 'hash', 'Anna', new \DateTimeImmutable())->email()));
    }

    public function testAnOrganizationNeedsAnIanaTimezone(): void
    {
        new Organization(Uuid::v7(), 'Acme', Currency::EUR, 'America/Argentina/Buenos_Aires', new \DateTimeImmutable());

        $this->expectException(\InvalidArgumentException::class);
        new Organization(Uuid::v7(), 'Acme', Currency::EUR, 'CEST', new \DateTimeImmutable());
    }

    public function testAMembershipIsRemovedOnce(): void
    {
        $membership = new Membership(Uuid::v7(), Uuid::v7(), Uuid::v7(), MembershipRole::Rep, new \DateTimeImmutable());
        self::assertSame(MembershipStatus::Active, $membership->status());
        self::assertNull($membership->removedAt());

        $membership->remove(new \DateTimeImmutable('2026-10-22T09:00:00Z'));
        self::assertSame(MembershipStatus::Removed, $membership->status());

        $this->expectException(\LogicException::class);
        $membership->remove(new \DateTimeImmutable());
    }

    public function testAStageIsArchivedOnce(): void
    {
        $stage = new PipelineStage(Uuid::v7(), Uuid::v7(), Uuid::v7(), 'Lead', 0);
        $stage->archive(new \DateTimeImmutable());

        $this->expectException(\LogicException::class);
        $stage->archive(new \DateTimeImmutable());
    }

    public function testAnAuditEventNeedsAValidIpAddress(): void
    {
        $this->expectException(\InvalidArgumentException::class);
        new AuditEvent(Uuid::v7(), null, new \DateTimeImmutable(), ActorType::System, null, null, 'x.created', 'x', null, [], null, '999.1.1.1');
    }
}
