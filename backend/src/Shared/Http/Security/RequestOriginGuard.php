<?php

declare(strict_types=1);

namespace App\Shared\Http\Security;

use App\Shared\Http\Problem\ProblemException;
use Monolog\Attribute\WithMonologChannel;
use Psr\Log\LoggerInterface;
use Symfony\Component\DependencyInjection\Attribute\Autowire;
use Symfony\Component\EventDispatcher\Attribute\AsEventListener;
use Symfony\Component\HttpFoundation\Request;
use Symfony\Component\HttpKernel\Event\RequestEvent;
use Symfony\Component\HttpKernel\KernelEvents;
use Symfony\Component\Security\Csrf\CsrfToken;
use Symfony\Component\Security\Csrf\CsrfTokenManagerInterface;

/**
 * Cross-site request forgery defence for every unsafe /api request
 * (POST, PUT, PATCH, DELETE; ADR-019), before the firewall runs (priority
 * 16: after routing at 32, before the firewall at 8), so it also covers
 * login and logout:
 *
 * 1. A request with a body must be application/json, otherwise 415: an
 *    HTML form or a text/plain "simple" request cannot carry one, and a
 *    cross-origin JSON request needs a CORS preflight, which fails (no CORS).
 *    A request without a body (logout) needs no media type.
 * 2. Origin policy: the Origin header must equal the request's own origin.
 *    Without Origin, the origin of the Referer must; without both, the
 *    request is refused. A Sec-Fetch-Site other than same-origin is refused.
 * 3. A request whose session is authenticated must send the session-bound
 *    token in X-CSRF-Token. Login is exempt (it has no session yet; its
 *    defence is 1 and 2). A request without an authenticated session cannot
 *    change anything: the firewall answers it with 401, and logout is a no-op.
 *
 * Failures are 403 csrf-invalid (415 for the media type) and are logged on
 * the security channel without header values.
 */
#[WithMonologChannel('security')]
final readonly class RequestOriginGuard
{
    public const TOKEN_ID = 'api';
    public const HEADER = 'X-CSRF-Token';

    /**
     * @param list<string> $exemptRoutes routes that need no token (login)
     */
    public function __construct(
        private CsrfTokenManagerInterface $tokens,
        private LoggerInterface $logger,
        #[Autowire('%flowcrm.security.session_token_key%')]
        private string $authenticatedSessionKey,
        #[Autowire('%flowcrm.security.csrf_exempt_routes%')]
        private array $exemptRoutes,
    ) {
    }

    #[AsEventListener(event: KernelEvents::REQUEST, priority: 16)]
    public function __invoke(RequestEvent $event): void
    {
        $request = $event->getRequest();
        $path = $request->getPathInfo();
        if (!$event->isMainRequest() || $request->isMethodSafe() || ('/api' !== $path && !str_starts_with($path, '/api/'))) {
            return;
        }

        // Only a body needs a media type: Caddy's FastCGI transport labels
        // every POST without a Content-Type as a form, also an empty one.
        if (self::hasBody($request) && 'json' !== $request->getContentTypeFormat()) {
            $this->reject($request, 'content_type');

            throw ProblemException::unsupportedMediaType();
        }

        $site = $request->headers->get('Sec-Fetch-Site');
        if (null !== $site && 'same-origin' !== $site) {
            $this->reject($request, 'fetch_site');

            throw ProblemException::csrfInvalid();
        }
        $origin = $request->headers->get('Origin') ?? self::originOf($request->headers->get('Referer'));
        if (null === $origin) {
            $this->reject($request, 'origin_missing');

            throw ProblemException::csrfInvalid();
        }
        if ($origin !== $request->getSchemeAndHttpHost()) {
            $this->reject($request, 'origin_mismatch');

            throw ProblemException::csrfInvalid();
        }

        if (\in_array($request->attributes->get('_route'), $this->exemptRoutes, true) || !$request->hasPreviousSession()) {
            return;
        }
        if (!$request->getSession()->has($this->authenticatedSessionKey)) {
            return;
        }
        $token = $request->headers->get(self::HEADER);
        if (null === $token || '' === $token || !$this->tokens->isTokenValid(new CsrfToken(self::TOKEN_ID, $token))) {
            $this->reject($request, null === $token || '' === $token ? 'token_missing' : 'token_invalid');

            throw ProblemException::csrfInvalid();
        }
    }

    /**
     * PHP parses form and multipart bodies itself (php://input is then
     * empty), so the length and the parsed data count too.
     */
    private static function hasBody(Request $request): bool
    {
        return (int) $request->headers->get('Content-Length', '0') > 0
            || '' !== $request->getContent()
            || $request->request->count() > 0
            || $request->files->count() > 0;
    }

    /** The origin (scheme://host[:port]) of a Referer, or null. */
    private static function originOf(?string $referer): ?string
    {
        if (null === $referer) {
            return null;
        }
        $parts = parse_url($referer);
        if (!\is_array($parts) || !isset($parts['scheme'], $parts['host'])) {
            return null;
        }

        return strtolower($parts['scheme']).'://'.strtolower($parts['host']).(isset($parts['port']) ? ':'.$parts['port'] : '');
    }

    private function reject(Request $request, string $reason): void
    {
        $route = $request->attributes->get('_route');
        $this->logger->warning('unsafe request rejected: {reason}', [
            'event' => 'request_rejected',
            'reason' => $reason,
            'method' => $request->getMethod(),
            'route' => \is_string($route) ? $route : null,
        ]);
    }
}
