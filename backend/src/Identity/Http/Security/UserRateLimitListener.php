<?php

declare(strict_types=1);

namespace App\Identity\Http\Security;

use App\Identity\Api\CurrentUser;
use App\Shared\Http\Problem\ProblemException;
use Monolog\Attribute\WithMonologChannel;
use Psr\Log\LoggerInterface;
use Symfony\Component\DependencyInjection\Attribute\Autowire;
use Symfony\Component\EventDispatcher\Attribute\AsEventListener;
use Symfony\Component\HttpKernel\Event\RequestEvent;
use Symfony\Component\HttpKernel\KernelEvents;
use Symfony\Component\RateLimiter\RateLimiterFactoryInterface;
use Symfony\Component\Security\Core\Authorization\Voter\AuthenticatedVoter;
use Symfony\Component\Security\Http\AccessMapInterface;

/**
 * The per-user API limit of FCRM-002 NFR-007: 600 requests per minute for
 * each logged-in user, then 429 with Retry-After (ADR-019).
 *
 * Runs after the firewall (priority 8), so only requests that the firewall
 * authenticated for a route that requires a login are counted, keyed by the
 * user ID: anonymous traffic, requests the request-origin guard refused and
 * other users can never use up a user's budget. The public routes (status,
 * session probe, login, logout) are not counted: login has its own limits,
 * and a limited user can always log out.
 */
#[WithMonologChannel('security')]
final readonly class UserRateLimitListener
{
    public function __construct(
        #[Autowire(service: 'security.access_map')]
        private AccessMapInterface $accessMap,
        private CurrentUser $currentUser,
        // Lazy: this listener runs for every request, and routes that count
        // nothing (such as /health/ready) must not need the database connection.
        #[Autowire(service: 'flowcrm.rate_limiter.api_user', lazy: true)]
        private RateLimiterFactoryInterface $limits,
        private LoggerInterface $logger,
    ) {
    }

    #[AsEventListener(event: KernelEvents::REQUEST, priority: 4)]
    public function __invoke(RequestEvent $event): void
    {
        $request = $event->getRequest();
        $path = $request->getPathInfo();
        if (!$event->isMainRequest() || ('/api' !== $path && !str_starts_with($path, '/api/'))) {
            return;
        }
        [$attributes] = $this->accessMap->getPatterns($request);
        if (null === $attributes || [] === $attributes || [AuthenticatedVoter::PUBLIC_ACCESS] === $attributes) {
            return;
        }
        $userId = $this->currentUser->id();
        if (null === $userId) {
            return;
        }

        $limit = $this->limits->create($userId->toRfc4122())->consume();
        if (!$limit->isAccepted()) {
            $this->logger->warning('api rate limit reached', ['event' => 'api_rate_limited', 'user_id' => $userId->toRfc4122()]);

            throw ProblemException::tooManyRequests($limit->getRetryAfter()->getTimestamp() - time());
        }
    }
}
