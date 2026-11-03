<?php

declare(strict_types=1);

namespace App\Shared\Http;

use Symfony\Component\EventDispatcher\Attribute\AsEventListener;
use Symfony\Component\HttpKernel\Event\ResponseEvent;
use Symfony\Component\HttpKernel\KernelEvents;

/**
 * API responses can carry the data of a logged-in user: no shared or
 * browser cache may store them (no-store, so the back button after a logout
 * shows nothing either), and caches that ignore that must key them on the
 * cookie (Vary: Cookie). Runs before the session listener (priority -1000),
 * which adds private and max-age=0 when the session was used.
 */
final readonly class ApiCacheHeaders
{
    #[AsEventListener(event: KernelEvents::RESPONSE, priority: -900)]
    public function __invoke(ResponseEvent $event): void
    {
        $path = $event->getRequest()->getPathInfo();
        if (!$event->isMainRequest() || ('/api' !== $path && !str_starts_with($path, '/api/'))) {
            return;
        }

        $headers = $event->getResponse()->headers;
        $headers->addCacheControlDirective('no-store');
        $vary = $headers->all('vary');
        if (!\in_array('Cookie', $vary, true)) {
            $headers->set('Vary', 'Cookie', false);
        }
    }
}
