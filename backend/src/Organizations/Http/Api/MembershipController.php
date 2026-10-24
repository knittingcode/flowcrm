<?php

declare(strict_types=1);

namespace App\Organizations\Http\Api;

use App\Organizations\Api\TenantContext;
use App\Organizations\Application\ActorNotMember;
use App\Organizations\Application\ActorNotPermitted;
use App\Organizations\Application\LastAdmin;
use App\Organizations\Application\ManageMemberships;
use App\Organizations\Application\MembershipExists;
use App\Organizations\Application\MembershipNotFound;
use App\Organizations\Application\MemberView;
use App\Organizations\Application\UnknownUser;
use App\Organizations\Domain\MembershipRole;
use App\Organizations\Domain\Permission;
use App\Organizations\Http\Tenant\TenantPermission;
use App\Shared\Http\Json\JsonBody;
use App\Shared\Http\Problem\ProblemException;
use App\Shared\Http\RequestId;
use Monolog\Attribute\WithMonologChannel;
use Psr\Log\LoggerInterface;
use Symfony\Component\HttpFoundation\JsonResponse;
use Symfony\Component\HttpFoundation\Request;
use Symfony\Component\HttpFoundation\Response;
use Symfony\Component\Routing\Attribute\Route;
use Symfony\Component\Routing\Requirement\Requirement;
use Symfony\Component\Security\Core\Authorization\AuthorizationCheckerInterface;
use Symfony\Component\Uid\Uuid;

/**
 * Membership administration of FCRM-FND-010C (ADR-020). TenantGuard has
 * checked the declared permission; ManageMemberships checks the actor again
 * under the organization lock. Refusals are logged on the security channel
 * (never with an e-mail address) and are not audited.
 *
 * Status order: 404 for the organization and 403 for the permission
 * (TenantGuard), then 404 for the target membership, then 422, then 409.
 */
#[WithMonologChannel('security')]
final readonly class MembershipController
{
    private const MEMBER = '/api/v1/organizations/{organizationId}/members/{membershipId}';
    private const REQUIREMENTS = ['organizationId' => Requirement::UUID, 'membershipId' => Requirement::UUID];

    public function __construct(
        private ManageMemberships $memberships,
        private AuthorizationCheckerInterface $authorization,
        private LoggerInterface $logger,
    ) {
    }

    /** An existing user joins with a role; one membership per user and organization, also after a removal. */
    #[Route('/api/v1/organizations/{organizationId}/members', name: 'api_v1_organization_member_add', requirements: ['organizationId' => Requirement::UUID], methods: ['POST'])]
    #[TenantPermission(Permission::MembershipAdd)]
    public function add(Request $request, TenantContext $tenant): JsonResponse
    {
        $body = JsonBody::strings($request, ['email', 'role']);
        $role = self::role($body['role']);
        $member = $this->refusals($request, $tenant, fn (): MemberView => $this->memberships->add($tenant->organizationId, $tenant->userId, $body['email'], $role, self::requestId($request)));

        $response = $this->member($member, $tenant, Response::HTTP_CREATED);
        $response->headers->set('Location', \sprintf('/api/v1/organizations/%s/members/%s', $tenant->organizationId->toRfc4122(), $member->membershipId->toRfc4122()));

        return $response;
    }

    /** The same role again is a 200 without a change. */
    #[Route(self::MEMBER, name: 'api_v1_organization_member_change_role', requirements: self::REQUIREMENTS, methods: ['PATCH'])]
    #[TenantPermission(Permission::MembershipChangeRole)]
    public function changeRole(Request $request, string $membershipId, TenantContext $tenant): JsonResponse
    {
        // The body is read once the membership is known: an unknown one is a 404 before any 422.
        $newRole = static fn (): MembershipRole => self::role(JsonBody::strings($request, ['role'])['role']);
        $member = $this->refusals($request, $tenant, fn (): MemberView => $this->memberships->changeRole($tenant->organizationId, $tenant->userId, Uuid::fromString($membershipId), $newRole, self::requestId($request)));

        return $this->member($member, $tenant, Response::HTTP_OK);
    }

    /** The membership becomes REMOVED; a repeated DELETE is a 404. */
    #[Route(self::MEMBER, name: 'api_v1_organization_member_remove', requirements: self::REQUIREMENTS, methods: ['DELETE'])]
    #[TenantPermission(Permission::MembershipRemove)]
    public function remove(Request $request, string $membershipId, TenantContext $tenant): Response
    {
        $this->refusals($request, $tenant, fn () => $this->memberships->remove($tenant->organizationId, $tenant->userId, Uuid::fromString($membershipId), self::requestId($request)));

        return new Response(status: Response::HTTP_NO_CONTENT);
    }

    private static function role(string $value): MembershipRole
    {
        return MembershipRole::tryFrom($value) ?? throw ProblemException::validation([['pointer' => '/role', 'code' => 'INVALID_ROLE']]);
    }

    private static function requestId(Request $request): Uuid
    {
        return Uuid::fromString(RequestId::of($request));
    }

    /** The member was read inside the change's transaction; nothing here reads the database. */
    private function member(MemberView $member, TenantContext $tenant, int $status): JsonResponse
    {
        return new JsonResponse(MemberJson::of($member, $this->authorization->isGranted(Permission::MembershipViewEmail->value, $tenant)), $status);
    }

    /**
     * Maps the refusals of ManageMemberships to problems.
     *
     * @template T
     *
     * @param callable(): T $action
     *
     * @return T
     */
    private function refusals(Request $request, TenantContext $tenant, callable $action): mixed
    {
        $context = [
            'user_id' => $tenant->userId->toRfc4122(),
            'organization_id' => $tenant->organizationId->toRfc4122(),
            'route' => $request->attributes->get('_route'),
        ];
        try {
            return $action();
        } catch (ActorNotMember) {
            $this->logger->notice('tenant access denied: no active membership', ['event' => 'tenant_not_found'] + $context);

            throw ProblemException::notFound();
        } catch (ActorNotPermitted $e) {
            $this->logger->warning('tenant access denied: {permission}', ['event' => 'authorization_denied', 'permission' => $e->permission->value, 'role' => $e->role] + $context);

            throw ProblemException::forbidden();
        } catch (MembershipNotFound) {
            $this->logger->notice('membership change refused: {reason}', ['event' => 'membership_change_refused', 'reason' => 'membership_not_found'] + $context);

            throw ProblemException::notFound();
        } catch (UnknownUser) {
            $this->logger->notice('membership change refused: {reason}', ['event' => 'membership_change_refused', 'reason' => 'unknown_user'] + $context);

            throw ProblemException::validation([['pointer' => '/email', 'code' => 'UNKNOWN_USER']]);
        } catch (MembershipExists) {
            $this->logger->notice('membership change refused: {reason}', ['event' => 'membership_change_refused', 'reason' => 'membership_exists'] + $context);

            throw ProblemException::conflict('MEMBERSHIP_EXISTS');
        } catch (LastAdmin) {
            $this->logger->notice('membership change refused: {reason}', ['event' => 'membership_change_refused', 'reason' => 'last_admin'] + $context);

            throw ProblemException::conflict('LAST_ADMIN');
        }
    }
}
