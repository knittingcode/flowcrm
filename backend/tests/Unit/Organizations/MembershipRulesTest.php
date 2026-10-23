<?php

declare(strict_types=1);

namespace App\Tests\Unit\Organizations;

use App\Organizations\Domain\LastAdminRule;
use App\Organizations\Domain\Membership;
use App\Organizations\Domain\MembershipRole;
use App\Organizations\Domain\MembershipStatus;
use PHPUnit\Framework\Attributes\DataProvider;
use PHPUnit\Framework\TestCase;
use Symfony\Component\Uid\Uuid;

/** Role changes and the last-admin rule (FCRM-002 BR-03). */
final class MembershipRulesTest extends TestCase
{
    public function testTheRoleOfAnActiveMembershipChanges(): void
    {
        $membership = self::membership(MembershipRole::Rep);

        $membership->changeRole(MembershipRole::Manager);

        self::assertSame(MembershipRole::Manager, $membership->role());
        self::assertSame(MembershipStatus::Active, $membership->status());
    }

    public function testARemovedMembershipKeepsItsRole(): void
    {
        $membership = self::membership(MembershipRole::Rep);
        $membership->remove(new \DateTimeImmutable());

        try {
            $membership->changeRole(MembershipRole::Admin);
            self::fail('a removed membership changed its role');
        } catch (\LogicException) {
            self::assertSame(MembershipRole::Rep, $membership->role());
        }
    }

    /**
     * @return iterable<string, array{MembershipRole, bool, MembershipRole|null, int, bool}>
     */
    public static function changes(): iterable
    {
        // target role, target removed, new role (null: removal), active ADMINs, violated
        yield 'demoting the only ADMIN' => [MembershipRole::Admin, false, MembershipRole::Manager, 1, true];
        yield 'demoting the only ADMIN to REP' => [MembershipRole::Admin, false, MembershipRole::Rep, 1, true];
        yield 'removing the only ADMIN' => [MembershipRole::Admin, false, null, 1, true];
        yield 'no active ADMIN counted (inconsistent count): still refused' => [MembershipRole::Admin, false, null, 0, true];
        yield 'demoting one of two ADMINs' => [MembershipRole::Admin, false, MembershipRole::Rep, 2, false];
        yield 'removing one of three ADMINs' => [MembershipRole::Admin, false, null, 3, false];
        yield 'the only ADMIN stays ADMIN' => [MembershipRole::Admin, false, MembershipRole::Admin, 1, false];
        yield 'demoting a MANAGER' => [MembershipRole::Manager, false, MembershipRole::Rep, 1, false];
        yield 'removing a REP' => [MembershipRole::Rep, false, null, 1, false];
        yield 'promoting a REP' => [MembershipRole::Rep, false, MembershipRole::Admin, 1, false];
        yield 'a removed ADMIN is no ADMIN' => [MembershipRole::Admin, true, null, 1, false];
    }

    #[DataProvider('changes')]
    public function testTheLastAdminRule(MembershipRole $role, bool $removed, ?MembershipRole $newRole, int $activeAdmins, bool $violated): void
    {
        $target = self::membership($role);
        if ($removed) {
            $target->remove(new \DateTimeImmutable());
        }

        self::assertSame($violated, LastAdminRule::violatedBy($target, $newRole, $activeAdmins));
    }

    private static function membership(MembershipRole $role): Membership
    {
        return new Membership(Uuid::v7(), Uuid::v7(), Uuid::v7(), $role, new \DateTimeImmutable());
    }
}
