<?php

declare(strict_types=1);

namespace App\Shared\Http\Problem;

use App\Shared\Http\RequestId;
use Symfony\Component\EventDispatcher\Attribute\AsEventListener;
use Symfony\Component\HttpFoundation\JsonResponse;
use Symfony\Component\HttpFoundation\Response;
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
    private const TYPES = [
        400 => 'bad-request',
        404 => 'not-found',
        405 => 'method-not-allowed',
        406 => 'not-acceptable',
        415 => 'unsupported-media-type',
        500 => 'internal-error',
        503 => 'service-unavailable',
    ];

    #[AsEventListener(event: KernelEvents::EXCEPTION, priority: -64)]
    public function __invoke(ExceptionEvent $event): void
    {
        $request = $event->getRequest();
        $path = $request->getPathInfo();
        if ('/api' !== $path && !str_starts_with($path, '/api/')) {
            return;
        }

        $exception = $event->getThrowable();
        $status = Response::HTTP_INTERNAL_SERVER_ERROR;
        $headers = [];
        if ($exception instanceof HttpExceptionInterface) {
            $status = $exception->getStatusCode();
            $headers = $exception->getHeaders();
        }

        $requestId = RequestId::of($request);
        $type = self::TYPES[$status] ?? null;
        $body = [
            'type' => null === $type ? 'about:blank' : '/problems/'.$type,
            'title' => Response::$statusTexts[$status] ?? 'Error',
            'status' => $status,
            'instance' => $path,
            'requestId' => $requestId,
        ];

        $response = new JsonResponse($body, $status, $headers);
        $response->headers->set('Content-Type', 'application/problem+json');
        $response->headers->set('Cache-Control', 'no-store');
        $event->setResponse($response);
    }
}
