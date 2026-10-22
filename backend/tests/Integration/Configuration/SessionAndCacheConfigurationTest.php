<?php

declare(strict_types=1);

namespace App\Tests\Integration\Configuration;

use PHPUnit\Framework\Attributes\DataProvider;
use Symfony\Bundle\FrameworkBundle\Test\KernelTestCase;
use Symfony\Component\Cache\Adapter\DoctrineDbalAdapter;
use Symfony\Component\HttpFoundation\Session\Storage\Handler\PdoSessionHandler;

/**
 * The session and cache settings of every environment, read from the
 * compiled container (config/packages/session.yaml and cache.yaml).
 */
final class SessionAndCacheConfigurationTest extends KernelTestCase
{
    /**
     * @return iterable<string, array{string, string, bool|string}>
     */
    public static function environments(): iterable
    {
        yield 'dev' => ['dev', 'flowcrm_sid', 'auto'];
        yield 'test' => ['test', 'flowcrm_sid', 'auto'];
        // __Host- requires Secure, Path=/ and no Domain.
        yield 'prod' => ['prod', '__Host-flowcrm_sid', true];
    }

    #[DataProvider('environments')]
    public function testSessionOptions(string $environment, string $name, bool|string $secure): void
    {
        $container = self::bootKernel(['environment' => $environment, 'debug' => false])->getContainer();

        self::assertSame([
            'cache_limiter' => '0',
            'name' => $name,
            'cookie_lifetime' => 0,
            'cookie_path' => '/',
            'cookie_secure' => $secure,
            'cookie_httponly' => true,
            'cookie_samesite' => 'lax',
            'gc_maxlifetime' => 1800,
            'gc_probability' => 1,
            'gc_divisor' => 100,
        ], $container->getParameter('session.storage.options'));
    }

    /** Dev and prod, and the cache prefix seed, are checked by tests/app/backend.sh. */
    public function testSessionsAndTheApplicationCacheUseTheDatabase(): void
    {
        $container = self::getContainer();

        self::assertInstanceOf(PdoSessionHandler::class, $container->get('session.handler'));
        self::assertInstanceOf(DoctrineDbalAdapter::class, $container->get('cache.app'));
    }
}
