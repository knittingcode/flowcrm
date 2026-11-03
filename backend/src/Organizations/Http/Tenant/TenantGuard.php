<?php

declare(strict_types=1);

namespace App\Organizations\Http\Tenant;

use App\Identity\Api\CurrentUser;
use App\Organizations\Api\TenantContext;
use App\Organizations\Application\OrganizationReadModel;
use App\Shared\Http\Problem\ProblemException;
use Monolog\Attribute\WithMonologChannel;
use Psr\Log\LoggerInterface;
use Symfony\Component\DependencyInjection\Attribute\Autowire;
use Symfony\Component\EventDispatcher\Attribute\AsEventListener;
use Symfony\Component\HttpKernel\Event\ControllerEvent;
use Symfony\Component\HttpKernel\KernelEvents;
use Symfony\Component\Security\Core\Authorization\AuthorizationCheckerInterface;
use Symfony\Component\Uid\Uuid;

/**
 * Tenant resolution and authorization for every route with an
 * {organizationId} (FCRM-003 section G, steps 5 and 6), after the firewall
 * required a logged-in user (401 before anything about organizations is
 * looked up):
 *
 * 1. The route must declare exactly one TenantPermission, otherwise the
 *    request fails (500, fail closed): there is no tenant route without a
 *    policy.
 * 2. The organization comes only from the validated route parameter, never
 *    from the session, the query, the body or a header.
 * 3. The current user's ACTIVE membership is loaded from the database on
 *    every request (no cache): none, a removed one and an unknown
 *    organization are the same 404.
 * 4. The voter decides the permission for the membership's role: 403.
 *
 * The resolved TenantContext is a request attribute for the controller.
 */
#[WithMonologChannel('security')]
final readonly class TenantGuard
{
    public function __construct(
        // Lazy: this listener runs for every controller, and routes without a
        // tenant (such as /health/ready) must not need the database connection.
        #[Autowire(lazy: true)]
        private OrganizationReadModel $organizations,
        private CurrentUser $currentUser,
        private AuthorizationCheckerInterface $authorization,
        private LoggerInterface $logger,
    ) {
    }

    #[AsEventListener(event: KernelEvents::CONTROLLER)]
    public function __invoke(ControllerEvent $event): void
    {
        $request = $event->getRequest();
        $params = $request->attributes->get('_route_params');
        $permissions = $event->getAttributes(TenantPermission::class);
        if (!\is_array($params) || !\array_key_exists('organizationId', $params)) {
            if ([] !== $permissions) {
                throw new \LogicException('TenantPermission on a route without {organizationId}.');
            }

            return;
        }
        if (1 !== \count($permissions)) {
            $route = $request->attributes->get('_route');

            throw new \LogicException(\sprintf('The tenant route "%s" must declare exactly one TenantPermission.', \is_string($route) ? $route : '?'));
        }
        $permission = $permissions[0]->permission;

        $userId = $this->currentUser->id() ?? throw ProblemException::unauthenticated();
        $organizationId = $params['organizationId'];
        $context = \is_string($organizationId) && Uuid::isValid($organizationId)
            ? $this->organizations->activeMembership(Uuid::fromString($organizationId), $userId)
            : null;
        if (null === $context) {
            $this->logger->notice('tenant access denied: no active membership', [
                'event' => 'tenant_not_found',
                'user_id' => $userId->toRfc4122(),
                'route' => $request->attributes->get('_route'),
            ]);

            throw ProblemException::notFound();
        }
        $request->attributes->set(TenantContext::ATTRIBUTE, $context);

        if (!$this->authorization->isGranted($permission->value, $context)) {
            $this->logger->warning('tenant access denied: {permission}', [
                'event' => 'authorization_denied',
                'permission' => $permission->value,
                'role' => $context->role,
                'user_id' => $userId->toRfc4122(),
                'organization_id' => $context->organizationId->toRfc4122(),
                'route' => $request->attributes->get('_route'),
            ]);

            throw ProblemException::forbidden();
        }
    }
}
