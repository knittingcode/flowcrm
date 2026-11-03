<?php

declare(strict_types=1);

namespace App\Identity\Http\Api;

use App\Identity\Domain\UserRepository;
use App\Organizations\Api\MembershipDirectory;
use App\Organizations\Api\MembershipSummary;
use App\Shared\Http\Problem\ProblemException;
use App\Shared\Http\Security\RequestOriginGuard;
use Symfony\Component\Security\Csrf\CsrfTokenManagerInterface;
use Symfony\Component\Uid\Uuid;

/**
 * The logged-in user as the SPA sees it (FCRM-002 REQ-005): profile, the
 * active memberships with the permissions of each role (for showing
 * controls only; the server decides), and the CSRF token for unsafe
 * requests, which the SPA keeps in memory.
 */
final readonly class SessionView
{
    public function __construct(
        private UserRepository $users,
        private MembershipDirectory $memberships,
        private CsrfTokenManagerInterface $csrf,
    ) {
    }

    /** @return array{user: array{id: string, email: string, displayName: string}, memberships: list<array<string, mixed>>, csrfToken: string} */
    public function of(Uuid $userId): array
    {
        $user = $this->users->ofId($userId) ?? throw ProblemException::unauthenticated();

        return [
            'user' => ['id' => $user->id()->toRfc4122(), 'email' => $user->email(), 'displayName' => $user->displayName()],
            'memberships' => array_map(static fn (MembershipSummary $m): array => [
                'organizationId' => $m->organizationId->toRfc4122(),
                'organizationName' => $m->organizationName,
                'membershipId' => $m->membershipId->toRfc4122(),
                'role' => $m->role,
                'permissions' => $m->permissions,
            ], $this->memberships->activeMembershipsOf($userId)),
            'csrfToken' => $this->csrf->getToken(RequestOriginGuard::TOKEN_ID)->getValue(),
        ];
    }
}
