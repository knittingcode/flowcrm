<?php

declare(strict_types=1);

namespace App\Organizations\Http\Api;

use App\Organizations\Api\TenantContext;
use App\Organizations\Application\MemberDirectory;
use App\Organizations\Application\MemberView;
use App\Organizations\Application\OrganizationReadModel;
use App\Organizations\Domain\MembershipRole;
use App\Organizations\Domain\Permission;
use App\Organizations\Domain\RolePolicy;
use App\Organizations\Http\Tenant\TenantPermission;
use App\Shared\Http\Problem\ProblemException;
use App\Shared\Http\Query\Pagination;
use Symfony\Component\HttpFoundation\JsonResponse;
use Symfony\Component\HttpFoundation\Request;
use Symfony\Component\Routing\Attribute\Route;
use Symfony\Component\Routing\Requirement\Requirement;
use Symfony\Component\Security\Core\Authorization\AuthorizationCheckerInterface;
use Symfony\Component\Uid\Uuid;

/**
 * Read-only organization endpoints of FCRM-FND-010B. TenantGuard has
 * resolved the active membership and checked the declared permission
 * before any of these runs; every query is filtered by the organization.
 */
final readonly class OrganizationController
{
    public function __construct(
        private OrganizationReadModel $organizations,
        private MemberDirectory $members,
        private AuthorizationCheckerInterface $authorization,
    ) {
    }

    #[Route('/api/v1/organizations/{organizationId}', name: 'api_v1_organization', requirements: ['organizationId' => Requirement::UUID], methods: ['GET'])]
    #[TenantPermission(Permission::OrganizationView)]
    public function organization(TenantContext $tenant): JsonResponse
    {
        $organization = $this->organizations->organization($tenant->organizationId) ?? throw ProblemException::notFound();

        return new JsonResponse([
            'id' => $organization->id->toRfc4122(),
            'name' => $organization->name,
            'currency' => $organization->currency,
            'timezone' => $organization->timezone,
            'membership' => [
                'id' => $tenant->membershipId->toRfc4122(),
                'role' => $tenant->role,
                'permissions' => array_map(static fn (Permission $p): string => $p->value, RolePolicy::permissionsOf(MembershipRole::from($tenant->role))),
            ],
        ]);
    }

    #[Route('/api/v1/organizations/{organizationId}/members', name: 'api_v1_organization_members', requirements: ['organizationId' => Requirement::UUID], methods: ['GET'])]
    #[TenantPermission(Permission::MembershipList)]
    public function members(Request $request, TenantContext $tenant): JsonResponse
    {
        $pagination = Pagination::of($request);
        [$members, $total] = $this->members->page($tenant->organizationId, $pagination->page, $pagination->pageSize);
        $withEmail = $this->authorization->isGranted(Permission::MembershipViewEmail->value, $tenant);

        return new JsonResponse([
            'data' => array_map(static fn (MemberView $member): array => self::view($member, $withEmail), $members),
            'meta' => ['page' => $pagination->page, 'pageSize' => $pagination->pageSize, 'total' => $total],
        ]);
    }

    /** A membership ID of another organization is a 404, like an unknown one. */
    #[Route('/api/v1/organizations/{organizationId}/members/{membershipId}', name: 'api_v1_organization_member', requirements: ['organizationId' => Requirement::UUID, 'membershipId' => Requirement::UUID], methods: ['GET'])]
    #[TenantPermission(Permission::MembershipList)]
    public function member(string $membershipId, TenantContext $tenant): JsonResponse
    {
        $member = $this->members->member($tenant->organizationId, Uuid::fromString($membershipId)) ?? throw ProblemException::notFound();

        return new JsonResponse(self::view($member, $this->authorization->isGranted(Permission::MembershipViewEmail->value, $tenant)));
    }

    /** @return array<string, string> */
    private static function view(MemberView $member, bool $withEmail): array
    {
        $view = [
            'membershipId' => $member->membershipId->toRfc4122(),
            'userId' => $member->userId->toRfc4122(),
            'displayName' => $member->displayName,
            'role' => $member->role,
        ];
        if ($withEmail) {
            $view['email'] = $member->email;
        }

        return $view;
    }
}
