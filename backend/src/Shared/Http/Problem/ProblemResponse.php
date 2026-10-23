<?php

declare(strict_types=1);

namespace App\Shared\Http\Problem;

use App\Shared\Http\RequestId;
use Symfony\Component\HttpFoundation\JsonResponse;
use Symfony\Component\HttpFoundation\Request;
use Symfony\Component\HttpFoundation\Response;

/**
 * Builds RFC 9457 application/problem+json responses: type, title, status,
 * instance and the request ID, plus the extension members of the problem.
 * Used by the exception listener and by the security handlers, which answer
 * before any controller runs.
 */
final class ProblemResponse
{
    private const TYPES = [
        400 => 'bad-request',
        401 => 'unauthenticated',
        403 => 'forbidden',
        404 => 'not-found',
        405 => 'method-not-allowed',
        406 => 'not-acceptable',
        409 => 'conflict',
        415 => 'unsupported-media-type',
        422 => 'validation-error',
        429 => 'too-many-requests',
        500 => 'internal-error',
        503 => 'service-unavailable',
    ];

    /**
     * @param array<string, mixed> $extensions
     * @param array<mixed>         $headers
     */
    public static function create(Request $request, int $status, ?string $type = null, array $extensions = [], array $headers = []): JsonResponse
    {
        $type ??= self::TYPES[$status] ?? null;
        $body = [
            'type' => null === $type ? 'about:blank' : '/problems/'.$type,
            'title' => Response::$statusTexts[$status] ?? 'Error',
            'status' => $status,
            'instance' => $request->getPathInfo(),
            'requestId' => RequestId::of($request),
        ] + $extensions;

        $response = new JsonResponse($body, $status, $headers);
        $response->headers->set('Content-Type', 'application/problem+json');
        $response->headers->set('Cache-Control', 'no-store');

        return $response;
    }

    public static function of(Request $request, ProblemException $problem): JsonResponse
    {
        return self::create($request, $problem->getStatusCode(), $problem->type(), $problem->extensions(), $problem->getHeaders());
    }
}
