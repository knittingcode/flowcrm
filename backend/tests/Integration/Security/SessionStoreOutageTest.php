<?php

declare(strict_types=1);

namespace App\Tests\Integration\Security;

use App\Tests\Support\Http\FpmApiTestCase;
use App\Tests\Support\Session\FpmServer;

/**
 * Without the database, a request with a session cookie cannot read its
 * session: every route that reads it answers a 500 problem document without
 * details (docs/architecture/sessions-and-cache.md), and the specification
 * must declare that answer. ApiClient checks every answer against
 * backend/openapi.yaml.
 */
final class SessionStoreOutageTest extends FpmApiTestCase
{
    public function testEveryRouteThatReadsTheSessionAnswersADeclaredProblemWithoutTheDatabase(): void
    {
        $user = $this->fixtures->user('outage');
        $organizationId = $this->fixtures->organization('outage');
        $organization = $organizationId->toRfc4122();
        $membership = $this->fixtures->member($organizationId, $user, 'ADMIN')->toRfc4122();
        $client = $this->client();
        $client->login($user->email, $user->password);

        $unavailable = new FpmServer(['DATABASE_HOST' => 'db-unavailable.invalid']);
        $unavailable->start();
        try {
            $outage = $this->client($client->clientIp(), $unavailable);
            $outage->useSessionId($client->sessionId());
            foreach (['/api/v1/auth/session', '/api/v1/me', "/api/v1/organizations/$organization", "/api/v1/organizations/$organization/members", "/api/v1/organizations/$organization/members/$membership"] as $uri) {
                $response = $outage->get($uri);
                self::assertSame(500, $response->status(), $uri);
                self::assertSame('/problems/internal-error', $response->problem(), $uri);
            }
            self::assertSame(503, $outage->get('/api/v1/system/status')->status(), 'the status route reports the database itself');
        } finally {
            $unavailable->remove();
        }
    }
}
