<?php

declare(strict_types=1);

namespace App\Tests\Support\Session;

use Symfony\Component\HttpFoundation\JsonResponse;
use Symfony\Component\HttpFoundation\Request;
use Symfony\Component\HttpFoundation\Response;
use Symfony\Component\Routing\Attribute\Route;

/**
 * Test-only HTTP entry points that use the session, for the tests that run
 * the real PHP-FPM against the real PostgreSQL (FpmSessionTest). Under /api,
 * like the future session routes, so errors are problem documents.
 * Registered only in the test environment (config/services.yaml, when@test);
 * tests/ is neither mounted in the dev stack nor part of the production
 * image. Responses never contain the session ID.
 */
final class SessionProbeController
{
    /**
     * With ?other_cookie=1, an unrelated cookie is queued first (through
     * PHP, like the session cookie), to show it survives a failing start.
     */
    #[Route('/api/_test/session', methods: ['GET'])]
    public function read(Request $request): JsonResponse
    {
        if ($request->query->getBoolean('other_cookie')) {
            setcookie('probe_other', 'kept', ['path' => '/', 'httponly' => true, 'samesite' => 'Lax']);
        }

        return new JsonResponse(['n' => $request->getSession()->get('n')]);
    }

    /** Read-modify-write with an optional pause, to expose lost updates. */
    #[Route('/api/_test/session/increment', methods: ['POST'])]
    public function increment(Request $request): JsonResponse
    {
        $session = $request->getSession();
        $n = $session->get('n');
        $n = \is_int($n) ? $n : 0;
        usleep(1000 * min(2000, max(0, $request->query->getInt('pause_ms'))));
        $session->set('n', $n + 1);

        return new JsonResponse(['n' => $n + 1]);
    }

    /**
     * What a login does: a new session ID, the data kept, the old ID
     * removed. Migrating is a no-op for a session that has not started, so
     * it is started first (as the security firewall does before a login).
     */
    #[Route('/api/_test/session/migrate', methods: ['POST'])]
    public function migrate(Request $request): JsonResponse
    {
        $session = $request->getSession();
        $session->start();
        $session->migrate(true);

        return new JsonResponse(['n' => $session->get('n')]);
    }

    /** What a logout does; started first for the same reason as migrate(). */
    #[Route('/api/_test/session/invalidate', methods: ['POST'])]
    public function invalidate(Request $request): Response
    {
        $session = $request->getSession();
        $session->start();
        $session->invalidate();

        return new Response(status: Response::HTTP_NO_CONTENT);
    }
}
