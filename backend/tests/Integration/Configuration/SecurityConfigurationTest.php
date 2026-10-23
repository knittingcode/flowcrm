<?php

declare(strict_types=1);

namespace App\Tests\Integration\Configuration;

use App\Identity\Infrastructure\Security\SecurityUser;
use PHPUnit\Framework\Attributes\DataProvider;
use Symfony\Bundle\FrameworkBundle\Console\Application;
use Symfony\Bundle\FrameworkBundle\Test\KernelTestCase;
use Symfony\Component\Console\Tester\CommandTester;
use Symfony\Component\HttpFoundation\Request;

/**
 * The security settings of dev and prod, read from the compiled containers
 * (the test environment lowers only the hashing cost).
 */
final class SecurityConfigurationTest extends KernelTestCase
{
    /** @return iterable<string, array{string}> */
    public static function deployedEnvironments(): iterable
    {
        yield 'dev' => ['dev'];
        yield 'prod' => ['prod'];
    }

    #[DataProvider('deployedEnvironments')]
    public function testPasswordsAreHashedWithArgon2idAtTheOwaspBaseline(string $environment): void
    {
        // The configured hasher of that environment, through the framework's own command.
        $tester = new CommandTester(new Application(self::bootKernel(['environment' => $environment, 'debug' => false]))->find('security:hash-password'));
        $tester->execute(['password' => 'a sufficiently long one', 'user-class' => SecurityUser::class], ['interactive' => false]);

        self::assertMatchesRegularExpression('/\$argon2id\$v=19\$m=19456,t=3,p=1\$/', $tester->getDisplay());
    }

    #[DataProvider('deployedEnvironments')]
    public function testTheSessionLifetimeAndTheRateLimitsAreTheDocumentedOnes(string $environment): void
    {
        $container = self::bootKernel(['environment' => $environment, 'debug' => false])->getContainer();

        self::assertSame('28800', $_SERVER['FLOWCRM_SESSION_ABSOLUTE_LIFETIME'] ?? null, 'backend/.env, not overridden');
        self::assertSame(['id' => 'login_account_ip', 'policy' => 'sliding_window', 'limit' => 5, 'interval' => '15 minutes'], $container->getParameter('flowcrm.rate_limit.login_account_ip'));
        self::assertSame(['id' => 'login_ip', 'policy' => 'sliding_window', 'limit' => 50, 'interval' => '15 minutes'], $container->getParameter('flowcrm.rate_limit.login_ip'));
        self::assertSame(['id' => 'login_account', 'policy' => 'sliding_window', 'limit' => 100, 'interval' => '1 day'], $container->getParameter('flowcrm.rate_limit.login_account'));
        self::assertSame(['id' => 'password_change', 'policy' => 'sliding_window', 'limit' => 5, 'interval' => '15 minutes'], $container->getParameter('flowcrm.rate_limit.password_change'));
    }

    /** Only the client address and the scheme come from the trusted edge; never the host or port. */
    public function testOnlyTheClientAddressAndSchemeAreTakenFromTheEdge(): void
    {
        self::bootKernel(['environment' => 'prod', 'debug' => false]);

        self::assertSame(Request::HEADER_X_FORWARDED_FOR | Request::HEADER_X_FORWARDED_PROTO, Request::getTrustedHeaderSet());
    }
}
