<?php

declare(strict_types=1);

namespace App\Tests\Support\Http;

use App\Tests\Support\Security\Fixtures;
use App\Tests\Support\Session\FpmServer;
use PHPUnit\Framework\Assert;
use Symfony\Bundle\FrameworkBundle\Console\Application;
use Symfony\Bundle\FrameworkBundle\Test\KernelTestCase;
use Symfony\Component\Console\Tester\CommandTester;

/**
 * API tests over real HTTP semantics: the real PHP-FPM with the test
 * environment's configuration, PdoSessionHandler and PostgreSQL (FpmServer),
 * driven by a browser-like ApiClient whose responses are checked against
 * the OpenAPI specification. The kernel is booted only for fixtures, the
 * database and operator commands.
 */
abstract class FpmApiTestCase extends KernelTestCase
{
    protected static FpmServer $fpm;
    protected Fixtures $fixtures;

    public static function setUpBeforeClass(): void
    {
        self::$fpm = new FpmServer();
        self::$fpm->start();
    }

    public static function tearDownAfterClass(): void
    {
        self::$fpm->remove();
    }

    protected function setUp(): void
    {
        self::bootKernel();
        $this->fixtures = Fixtures::from(self::getContainer());
    }

    protected function tearDown(): void
    {
        self::assertDoesNotMatchRegularExpression('/PHP (Warning|Notice|Deprecated|Fatal error)/', self::$fpm->log());
        parent::tearDown();
    }

    protected function client(?string $clientIp = null, ?FpmServer $server = null): ApiClient
    {
        return new ApiClient($server ?? self::$fpm, $clientIp);
    }

    protected static function int(mixed $value): int
    {
        Assert::assertIsInt($value);

        return $value;
    }

    protected static function string(mixed $value): string
    {
        if (\is_resource($value)) {
            $value = stream_get_contents($value);
        }
        Assert::assertIsString($value);

        return $value;
    }

    /** The stored session data, or null when the row does not exist. */
    protected function sessionData(?string $sessionId): ?string
    {
        if (null === $sessionId) {
            return null;
        }
        $data = $this->fixtures->connection()->fetchOne('SELECT sess_data FROM sessions WHERE sess_id = ?', [$sessionId]);

        return false === $data ? null : self::string($data);
    }

    /**
     * Runs an operator command of the console (the real command, as the
     * runtime role); $stdin is its standard input.
     *
     * @param array<string, string> $input
     */
    protected function console(string $name, array $input = [], ?string $stdin = null): CommandTester
    {
        \assert(null !== self::$kernel);
        $tester = new CommandTester(new Application(self::$kernel)->find($name));
        if (null !== $stdin) {
            $tester->setInputs([$stdin]);
        }
        $tester->execute($input, ['interactive' => false]);

        return $tester;
    }
}
