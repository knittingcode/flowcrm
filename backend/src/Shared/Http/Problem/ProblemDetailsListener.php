<?php

declare(strict_types=1);

namespace App\Shared\Http\Problem;

use Symfony\Component\EventDispatcher\Attribute\AsEventListener;
use Symfony\Component\HttpKernel\Event\ExceptionEvent;
use Symfony\Component\HttpKernel\Exception\HttpExceptionInterface;
use Symfony\Component\HttpKernel\KernelEvents;

/**
 * Renders every exception under /api as RFC 9457 application/problem+json.
 * Exception messages and traces never reach the client. The framework's
 * error listener logs the exception; the log record and the problem
 * document carry the same request ID.
 */
final readonly class ProblemDetailsListener
{
    #[AsEventListener(event: KernelEvents::EXCEPTION, priority: -64)]
    public function __invoke(ExceptionEvent $event): void
    {
        $request = $event->getRequest();
        $path = $request->getPathInfo();
        if ('/api' !== $path && !str_starts_with($path, '/api/')) {
            return;
        }

        $exception = $event->getThrowable();
        if ($exception instanceof ProblemException) {
            $event->setResponse(ProblemResponse::of($request, $exception));

            return;
        }

        $status = 500;
        $headers = [];
        if ($exception instanceof HttpExceptionInterface) {
            $status = $exception->getStatusCode();
            $headers = $exception->getHeaders();
        }

        $event->setResponse(ProblemResponse::create($request, $status, headers: $headers));
    }
}
