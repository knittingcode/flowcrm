<?php

declare(strict_types=1);

namespace App\Tests\Integration\Shared;

use Symfony\Bundle\FrameworkBundle\Test\WebTestCase;

/**
 * Boots the kernel against the real PostgreSQL of the test project.
 */
final class HttpEndpointsTest extends WebTestCase
{
    public function testLiveness(): void
    {
        $client = self::createClient();
        $client->request('GET', '/health/live');

        self::assertResponseStatusCodeSame(200);
        self::assertSame('{"status":"live"}', $client->getResponse()->getContent());
    }

    public function testReadinessWithAMigratedDatabase(): void
    {
        $client = self::createClient();
        $client->request('GET', '/health/ready');

        self::assertResponseStatusCodeSame(200);
        self::assertSame('{"status":"ready"}', $client->getResponse()->getContent());
    }

    /**
     * A database credential that cannot be read (a missing secret file) makes
     * the API not ready (503 with the usual body and request ID), not a 500:
     * the check is built only when it runs.
     */
    public function testReadinessWithAnUnavailableCredentialIsNotReady(): void
    {
        $server = $_SERVER['DATABASE_PASSWORD_FILE'] ?? null;
        $env = $_ENV['DATABASE_PASSWORD_FILE'] ?? null;
        $_SERVER['DATABASE_PASSWORD_FILE'] = $_ENV['DATABASE_PASSWORD_FILE'] = '/run/secrets/does-not-exist';
        try {
            $client = self::createClient();
            $client->request('GET', '/health/ready');

            self::assertResponseStatusCodeSame(503);
            self::assertSame('{"status":"not-ready"}', $client->getResponse()->getContent());
            self::assertResponseHasHeader('X-Request-Id');
        } finally {
            unset($_SERVER['DATABASE_PASSWORD_FILE'], $_ENV['DATABASE_PASSWORD_FILE']);
            if (null !== $server) {
                $_SERVER['DATABASE_PASSWORD_FILE'] = $server;
            }
            if (null !== $env) {
                $_ENV['DATABASE_PASSWORD_FILE'] = $env;
            }
        }
    }

    public function testSystemStatusReadsFromTheDatabase(): void
    {
        $client = self::createClient();
        $client->request('GET', '/api/v1/system/status', server: ['HTTP_ACCEPT' => 'application/json']);

        self::assertResponseIsSuccessful();
        self::assertResponseHeaderSame('Content-Type', 'application/json');
        $body = json_decode((string) $client->getResponse()->getContent(), true, flags: \JSON_THROW_ON_ERROR);
        self::assertIsArray($body);
        self::assertSame('flowcrm-api', $body['service']);
        self::assertSame('v1', $body['apiVersion']);
        self::assertIsString($body['databaseTime']);
        self::assertMatchesRegularExpression('/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/', $body['databaseTime']);
        $skew = abs(new \DateTimeImmutable($body['databaseTime'])->getTimestamp() - time());
        self::assertLessThan(120, $skew, 'database time is current');
    }

    public function testUnknownApiRouteIsAProblemDocument(): void
    {
        $client = self::createClient();
        $client->request('GET', '/api/v1/does-not-exist');

        self::assertResponseStatusCodeSame(404);
        self::assertResponseHeaderSame('Content-Type', 'application/problem+json');
        $body = json_decode((string) $client->getResponse()->getContent(), true, flags: \JSON_THROW_ON_ERROR);
        self::assertIsArray($body);
        self::assertSame('/problems/not-found', $body['type']);
        self::assertResponseHasHeader('X-Request-Id');
        self::assertSame($client->getResponse()->headers->get('X-Request-Id'), $body['requestId']);
    }

    public function testWrongMethodIsAProblemDocument(): void
    {
        $client = self::createClient();
        $client->request('DELETE', '/api/v1/system/status');

        self::assertResponseStatusCodeSame(405);
        self::assertResponseHeaderSame('Content-Type', 'application/problem+json');
        self::assertResponseHeaderSame('Allow', 'GET');
    }
}
