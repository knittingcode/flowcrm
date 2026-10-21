<?php

declare(strict_types=1);

namespace App\Shared\Http\Api;

use App\Shared\Infrastructure\Database\DatabaseProbe;
use Psr\Log\LoggerInterface;
use Symfony\Component\HttpFoundation\JsonResponse;
use Symfony\Component\HttpKernel\Exception\ServiceUnavailableHttpException;
use Symfony\Component\Routing\Attribute\Route;

/**
 * Smoke-test endpoint of API v1: answers with data read from PostgreSQL, so a
 * successful response proves browser → edge → PHP-FPM → database.
 */
final readonly class SystemStatusController
{
    public function __construct(
        private DatabaseProbe $database,
        private LoggerInterface $logger,
    ) {
    }

    #[Route('/api/v1/system/status', name: 'api_v1_system_status', methods: ['GET'])]
    public function __invoke(): JsonResponse
    {
        try {
            $databaseTime = $this->database->databaseTime();
        } catch (\Throwable $e) {
            $this->logger->error('System status: database unavailable: {exception}', ['exception' => $e::class.': '.$e->getMessage()]);

            throw new ServiceUnavailableHttpException(null, 'The database is not available.');
        }

        $response = new JsonResponse([
            'service' => 'flowcrm-api',
            'apiVersion' => 'v1',
            'databaseTime' => $databaseTime->format('Y-m-d\TH:i:s\Z'),
        ]);
        $response->headers->set('Cache-Control', 'no-store');

        return $response;
    }
}
