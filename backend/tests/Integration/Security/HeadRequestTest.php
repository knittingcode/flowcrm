<?php

declare(strict_types=1);

namespace App\Tests\Integration\Security;

use App\Tests\Support\Http\ApiClient;
use App\Tests\Support\Http\FpmApiTestCase;

/**
 * The router serves HEAD with the GET handler, so a HEAD request must meet the
 * same access decisions as GET (CVE-2026-118514 is this gap in Symfony's method
 * matcher). Over the real PHP-FPM; these requests bypass ApiClient only because
 * the OpenAPI specification describes GET.
 */
final class HeadRequestTest extends FpmApiTestCase
{
    public function testAnAnonymousHeadRequestToAProtectedRouteIsRefusedLikeGet(): void
    {
        self::assertSame(401, self::$fpm->request('GET', '/api/v1/me')->status);

        $head = self::$fpm->request('HEAD', '/api/v1/me');

        self::assertSame(401, $head->status);
        self::assertSame('', $head->body);
    }

    public function testAHeadRequestToAForeignOrganizationIsAnsweredLikeGet(): void
    {
        $own = $this->fixtures->organization('own');
        $foreign = $this->fixtures->organization('foreign');
        $user = $this->fixtures->user('head-member');
        $this->fixtures->member($own, $user, 'REP');
        $client = $this->client();
        $client->login($user->email, $user->password);
        $cookies = [ApiClient::COOKIE => (string) $client->sessionId()];

        $ownUri = '/api/v1/organizations/'.$own->toRfc4122();
        $foreignUri = '/api/v1/organizations/'.$foreign->toRfc4122();

        self::assertSame(200, self::$fpm->request('GET', $ownUri, $cookies)->status);
        $head = self::$fpm->request('HEAD', $ownUri, $cookies);
        self::assertSame(200, $head->status);
        self::assertSame('', $head->body);

        self::assertSame(404, self::$fpm->request('GET', $foreignUri, $cookies)->status);
        self::assertSame(404, self::$fpm->request('HEAD', $foreignUri, $cookies)->status);
    }
}
