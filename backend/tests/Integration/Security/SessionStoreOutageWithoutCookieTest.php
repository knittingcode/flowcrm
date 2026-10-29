<?php

declare(strict_types=1);

namespace App\Tests\Integration\Security;

use App\Tests\Support\Http\ApiClient;
use App\Tests\Support\Http\FpmApiTestCase;
use App\Tests\Support\Session\FpmServer;

/**
 * Pins the cookie-less half of the SessionUnavailable response in
 * backend/openapi.yaml (ApiClient checks every answer against it): without
 * a session cookie, the session probe reads no session and stays available
 * while the database is not, but an anonymous GET to a route that needs a
 * login starts a session (the firewall records the requested URL before
 * calling ProblemEntryPoint, docs/architecture/authentication.md, known
 * limitations) and therefore answers the 500 instead of the 401. Once that
 * route stops starting a session, this becomes a 401 and the specification
 * must say so.
 */
final class SessionStoreOutageWithoutCookieTest extends FpmApiTestCase
{
    public function testWithoutASessionCookieOnlyRoutesThatStartASessionFail(): void
    {
        $unavailable = new FpmServer(['DATABASE_HOST' => 'db-unavailable.invalid']);
        $unavailable->start();
        try {
            $client = $this->client(server: $unavailable);

            $session = $client->get('/api/v1/auth/session');
            self::assertSame(200, $session->status());
            self::assertSame(['authenticated' => false], $session->json());
            self::assertSame([], $session->raw->header('Set-Cookie'), 'no session was started');

            $me = $client->get('/api/v1/me');
            self::assertSame(500, $me->status(), 'the firewall could not start the session for the target path');
            self::assertSame('/problems/internal-error', $me->problem());
            self::assertNull($client->sessionId(), 'no session cookie was set');
            self::assertStringNotContainsString(ApiClient::COOKIE, implode("\n", $me->raw->header('Set-Cookie')));
        } finally {
            $unavailable->remove();
        }
    }
}
