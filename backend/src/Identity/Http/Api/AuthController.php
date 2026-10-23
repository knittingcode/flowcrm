<?php

declare(strict_types=1);

namespace App\Identity\Http\Api;

use App\Audit\Api\Actor;
use App\Audit\Api\AuditRecord;
use App\Audit\Api\AuditTrail;
use App\Identity\Api\CurrentUser;
use App\Identity\Application\CurrentSession;
use App\Identity\Http\Security\LoginAuditListener;
use App\Shared\Http\RequestId;
use Monolog\Attribute\WithMonologChannel;
use Psr\Log\LoggerInterface;
use Symfony\Component\HttpFoundation\JsonResponse;
use Symfony\Component\HttpFoundation\Request;
use Symfony\Component\HttpFoundation\Response;
use Symfony\Component\HttpKernel\Exception\BadRequestHttpException;
use Symfony\Component\Routing\Attribute\Route;
use Symfony\Component\Security\Core\Authentication\Token\Storage\TokenStorageInterface;
use Symfony\Component\Uid\Uuid;

/**
 * Login, logout and session introspection (ADR-019). The firewall's
 * json_login authenticates POST /api/v1/auth/login (generic 401 or 429 from
 * LoginFailureHandler); only a request it authenticated reaches login().
 */
#[WithMonologChannel('security')]
final readonly class AuthController
{
    public function __construct(
        private CurrentUser $currentUser,
        private CurrentSession $session,
        private SessionView $view,
        private TokenStorageInterface $tokens,
        private AuditTrail $audit,
        private LoggerInterface $logger,
    ) {
    }

    /**
     * 200 for anonymous visitors too ({"authenticated": false}), so the SPA
     * can ask on every page load. Without a session cookie no session starts.
     */
    #[Route('/api/v1/auth/session', name: 'api_v1_auth_session', methods: ['GET'])]
    public function session(): JsonResponse
    {
        $userId = $this->currentUser->id();
        if (null === $userId) {
            return new JsonResponse(['authenticated' => false]);
        }

        return new JsonResponse($this->authenticated($userId));
    }

    /**
     * Reached after json_login authenticated this request and the session
     * got a new ID; answers with the session, including a new CSRF token.
     */
    #[Route('/api/v1/auth/login', name: 'api_v1_auth_login', methods: ['POST'])]
    public function login(Request $request): JsonResponse
    {
        $userId = $this->currentUser->id();
        if (true !== $request->attributes->get(LoginAuditListener::AUTHENTICATED) || null === $userId) {
            // Not a JSON login request (json_login did not run): no credentials.
            throw new BadRequestHttpException('No credentials.');
        }

        return new JsonResponse($this->authenticated($userId));
    }

    /**
     * Ends the session on the server (the row is deleted, the cookie
     * expired). 204 also without a session: there is nothing to end.
     */
    #[Route('/api/v1/auth/logout', name: 'api_v1_auth_logout', methods: ['POST'])]
    public function logout(Request $request): Response
    {
        $userId = $this->currentUser->id();
        // The session ends first: a failing audit write must not keep it alive.
        $this->tokens->setToken(null);
        if ($request->hasPreviousSession()) {
            $request->getSession()->invalidate();
        }
        if (null !== $userId) {
            $this->audit->record(new AuditRecord('auth.logout', 'user', $userId, Actor::user($userId), requestId: Uuid::fromString(RequestId::of($request))));
            $this->logger->info('logout', ['event' => 'logout', 'user_id' => $userId->toRfc4122()]);
        }

        return new Response(status: Response::HTTP_NO_CONTENT);
    }

    /** @return array<string, mixed> */
    private function authenticated(Uuid $userId): array
    {
        return ['authenticated' => true] + $this->view->of($userId) + ['expiresAt' => $this->session->expiresAt()?->format('Y-m-d\TH:i:s\Z')];
    }
}
