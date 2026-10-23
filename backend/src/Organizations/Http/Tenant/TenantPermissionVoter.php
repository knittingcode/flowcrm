<?php

declare(strict_types=1);

namespace App\Organizations\Http\Tenant;

use App\Organizations\Api\TenantContext;
use App\Organizations\Domain\MembershipRole;
use App\Organizations\Domain\Permission;
use App\Organizations\Domain\RolePolicy;
use Symfony\Component\Security\Core\Authentication\Token\TokenInterface;
use Symfony\Component\Security\Core\Authorization\Voter\Vote;
use Symfony\Component\Security\Core\Authorization\Voter\Voter;

/**
 * Decides a Permission for a TenantContext with the static RolePolicy. The
 * context must belong to the logged-in user: a context of someone else is
 * denied whatever its role.
 *
 * @extends Voter<string, TenantContext>
 */
final class TenantPermissionVoter extends Voter
{
    public function supportsAttribute(string $attribute): bool
    {
        return null !== Permission::tryFrom($attribute);
    }

    public function supportsType(string $subjectType): bool
    {
        return TenantContext::class === $subjectType;
    }

    protected function supports(string $attribute, mixed $subject): bool
    {
        return $subject instanceof TenantContext && null !== Permission::tryFrom($attribute);
    }

    protected function voteOnAttribute(string $attribute, mixed $subject, TokenInterface $token, ?Vote $vote = null): bool
    {
        $permission = Permission::tryFrom($attribute);

        return null !== $permission
            && $token->getUserIdentifier() === $subject->userId->toRfc4122()
            && RolePolicy::grants(MembershipRole::from($subject->role), $permission);
    }
}
