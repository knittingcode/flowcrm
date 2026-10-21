<?php

declare(strict_types=1);

namespace App\Shared\Http\Health;

use App\Shared\Application\Health\ReadinessCheck;
use Monolog\Attribute\WithMonologChannel;
use Psr\Log\LoggerInterface;
use Symfony\Component\HttpFoundation\JsonResponse;
use Symfony\Component\HttpFoundation\Response;
use Symfony\Component\Routing\Attribute\Route;

/**
 * Infrastructure health endpoints (ADR-017). Responses carry only a status
 * word; reasons are logged on the health channel, never returned.
 */
#[WithMonologChannel('health')]
final readonly class HealthController
{
    public function __construct(
        private ReadinessCheck $readiness,
        private LoggerInterface $logger,
    ) {
    }

    /** The PHP process serves requests; no dependency is touched. */
    #[Route('/health/live', name: 'health_live', methods: ['GET', 'HEAD'])]
    public function live(): JsonResponse
    {
        return self::respond(Response::HTTP_OK, 'live');
    }

    /** PostgreSQL answers and every migration has been applied. */
    #[Route('/health/ready', name: 'health_ready', methods: ['GET', 'HEAD'])]
    public function ready(): JsonResponse
    {
        try {
            $result = $this->readiness->check();
            $reason = $result->reason;
        } catch (\Throwable $e) {
            $result = null;
            $reason = $e::class.': '.$e->getMessage();
        }

        if (null !== $result && $result->ready) {
            return self::respond(Response::HTTP_OK, 'ready');
        }

        $this->logger->warning('Readiness check failed: {reason}', ['reason' => $reason]);

        return self::respond(Response::HTTP_SERVICE_UNAVAILABLE, 'not-ready');
    }

    private static function respond(int $status, string $word): JsonResponse
    {
        $response = new JsonResponse(['status' => $word], $status);
        $response->headers->set('Cache-Control', 'no-store');

        return $response;
    }
}
