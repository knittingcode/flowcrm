<?php

declare(strict_types=1);

namespace App\Tests\Unit\Organizations;

use App\Organizations\Api\TenantContext;
use App\Organizations\Http\Tenant\TenantPermissionVoter;
use PHPUnit\Framework\TestCase;
use Symfony\Component\Security\Core\Authentication\Token\UsernamePasswordToken;
use Symfony\Component\Security\Core\Authorization\Voter\VoterInterface;
use Symfony\Component\Security\Core\User\InMemoryUser;
use Symfony\Component\Uid\Uuid;

final class TenantPermissionVoterTest extends TestCase
{
    public function testItDecidesByTheRoleOfTheUsersOwnMembership(): void
    {
        $user = Uuid::v7();
        $voter = new TenantPermissionVoter();
        $token = new UsernamePasswordToken(new InMemoryUser($user->toRfc4122(), null), 'api');

        self::assertSame(VoterInterface::ACCESS_GRANTED, $voter->vote($token, $this->context($user, 'MANAGER'), ['membership.view_email']));
        self::assertSame(VoterInterface::ACCESS_DENIED, $voter->vote($token, $this->context($user, 'REP'), ['membership.view_email']));
        self::assertSame(VoterInterface::ACCESS_DENIED, $voter->vote($token, $this->context(Uuid::v7(), 'ADMIN'), ['organization.view']), 'a context of someone else');
        self::assertSame(VoterInterface::ACCESS_ABSTAIN, $voter->vote($token, $this->context($user, 'ADMIN'), ['organization.delete']), 'an unknown permission');
        self::assertSame(VoterInterface::ACCESS_ABSTAIN, $voter->vote($token, null, ['organization.view']), 'no tenant');
    }

    private function context(Uuid $user, string $role): TenantContext
    {
        return new TenantContext(Uuid::v7(), Uuid::v7(), $user, $role);
    }
}
