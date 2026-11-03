<?php

declare(strict_types=1);

namespace App\Identity\Http\Api;

use App\Identity\Api\CurrentUser;
use App\Identity\Application\ChangeOwnPassword;
use App\Identity\Application\CurrentSession;
use App\Identity\Application\PasswordRejected;
use App\Identity\Application\WrongCurrentPassword;
use App\Shared\Http\Json\JsonBody;
use App\Shared\Http\Problem\ProblemException;
use App\Shared\Http\RequestId;
use Monolog\Attribute\WithMonologChannel;
use Psr\Log\LoggerInterface;
use Symfony\Component\DependencyInjection\Attribute\Autowire;
use Symfony\Component\HttpFoundation\JsonResponse;
use Symfony\Component\HttpFoundation\Request;
use Symfony\Component\HttpFoundation\Response;
use Symfony\Component\RateLimiter\RateLimiterFactoryInterface;
use Symfony\Component\Routing\Attribute\Route;
use Symfony\Component\Uid\Uuid;

/** The logged-in user's own profile and password (the firewall requires a session). */
#[WithMonologChannel('security')]
final readonly class MeController
{
    public function __construct(
        private CurrentUser $currentUser,
        private SessionView $view,
        private ChangeOwnPassword $changePassword,
        private CurrentSession $session,
        #[Autowire(service: 'flowcrm.rate_limiter.password_change')]
        private RateLimiterFactoryInterface $limits,
        private LoggerInterface $logger,
    ) {
    }

    #[Route('/api/v1/me', name: 'api_v1_me', methods: ['GET'])]
    public function me(): JsonResponse
    {
        return new JsonResponse($this->view->of($this->userId()));
    }

    /**
     * FCRM-002 REQ-006. Wrong current passwords are limited per user (5 per
     * 15 minutes) before anything is hashed. On success the session gets a
     * new ID and stays logged in; every other session of the user ends.
     */
    #[Route('/api/v1/me/password', name: 'api_v1_me_password', methods: ['POST'])]
    public function changePassword(Request $request): Response
    {
        $userId = $this->userId();
        $body = JsonBody::strings($request, ['currentPassword', 'newPassword']);
        $limiter = $this->limits->create($userId->toRfc4122());
        $limit = $limiter->consume(0);
        if (0 === $limit->getRemainingTokens()) {
            throw ProblemException::tooManyRequests($limit->getRetryAfter()->getTimestamp() - time());
        }

        try {
            ($this->changePassword)($userId, $body['currentPassword'], $body['newPassword'], Uuid::fromString(RequestId::of($request)));
        } catch (PasswordRejected $e) {
            throw ProblemException::validation(array_map(static fn (string $code): array => ['pointer' => '/newPassword', 'code' => $code], $e->violations));
        } catch (WrongCurrentPassword) {
            $limiter->consume();
            $this->logger->warning('password change refused: wrong current password', ['event' => 'password_change_failed', 'user_id' => $userId->toRfc4122()]);

            throw ProblemException::validation([['pointer' => '/currentPassword', 'code' => 'INVALID_CURRENT_PASSWORD']]);
        }
        $limiter->reset();
        $this->session->credentialsChanged();
        $this->logger->info('password changed', ['event' => 'password_changed', 'user_id' => $userId->toRfc4122()]);

        return new Response(status: Response::HTTP_NO_CONTENT);
    }

    private function userId(): Uuid
    {
        return $this->currentUser->id() ?? throw ProblemException::unauthenticated();
    }
}
