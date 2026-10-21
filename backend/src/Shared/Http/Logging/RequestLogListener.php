<?php

declare(strict_types=1);

namespace App\Shared\Http\Logging;

use Monolog\Attribute\WithMonologChannel;
use Psr\Log\LoggerInterface;
use Psr\Log\LogLevel;
use Symfony\Component\EventDispatcher\Attribute\AsEventListener;
use Symfony\Component\HttpKernel\Event\ResponseEvent;
use Symfony\Component\HttpKernel\KernelEvents;

/**
 * Writes one "request completed" record per request on the http channel:
 * method, route, status and duration. Request counts, latency and error
 * rates are derived from these records (FCRM-003 section Q: metrics from
 * logs). Paths, query strings, headers and bodies are not logged. Health
 * checks are logged at debug level, below the level of the log handlers.
 */
#[WithMonologChannel('http')]
final readonly class RequestLogListener
{
    public function __construct(private LoggerInterface $logger)
    {
    }

    #[AsEventListener(event: KernelEvents::RESPONSE, priority: -1024)]
    public function __invoke(ResponseEvent $event): void
    {
        if (!$event->isMainRequest()) {
            return;
        }

        $request = $event->getRequest();
        $route = $request->attributes->get('_route');
        $route = \is_string($route) ? $route : null;
        $started = $request->server->get('REQUEST_TIME_FLOAT');
        $duration = \is_float($started) || \is_int($started) ? round((microtime(true) - $started) * 1000, 1) : null;

        $this->logger->log(null !== $route && str_starts_with($route, 'health_') ? LogLevel::DEBUG : LogLevel::INFO, 'request completed', [
            'method' => $request->getMethod(),
            'route' => $route,
            'status' => $event->getResponse()->getStatusCode(),
            'duration_ms' => $duration,
        ]);
    }
}
