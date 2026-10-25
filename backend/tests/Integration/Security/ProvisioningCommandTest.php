<?php

declare(strict_types=1);

namespace App\Tests\Integration\Security;

use Doctrine\DBAL\Connection;
use Symfony\Bundle\FrameworkBundle\Console\Application;
use Symfony\Bundle\FrameworkBundle\Test\KernelTestCase;
use Symfony\Component\Console\Command\Command;
use Symfony\Component\Console\Tester\CommandTester;

/**
 * The operator console (FCRM-002: no public registration, no unauthenticated
 * organization administration): passwords only from standard input, never
 * printed; invalid input refused without changes.
 */
final class ProvisioningCommandTest extends KernelTestCase
{
    private const COMMANDS = ['flowcrm:user:create', 'flowcrm:user:reset-password', 'flowcrm:user:disable', 'flowcrm:user:enable', 'flowcrm:organization:create', 'flowcrm:membership:add'];

    public function testNoCommandTakesAPasswordAsAnArgumentOrOption(): void
    {
        $application = new Application(self::bootKernel());
        foreach (self::COMMANDS as $name) {
            $definition = $application->find($name)->getDefinition();
            foreach ([...array_keys($definition->getArguments()), ...array_keys($definition->getOptions())] as $parameter) {
                self::assertStringNotContainsStringIgnoringCase('pass', $parameter, $name);
            }
        }
    }

    public function testAUserIsCreatedWithAPasswordFromStandardInput(): void
    {
        $email = 'created-'.bin2hex(random_bytes(4)).'@example.test';

        $tester = $this->command('flowcrm:user:create', ['--email' => $email, '--display-name' => 'Created'], 'a sufficiently long one');

        self::assertSame(Command::SUCCESS, $tester->getStatusCode(), $tester->getDisplay());
        self::assertStringNotContainsString('a sufficiently long one', $tester->getDisplay());
        $hash = $this->db()->fetchOne('SELECT password_hash FROM users WHERE email = ?', [$email]);
        self::assertIsString($hash);
        self::assertStringStartsWith('$argon2id$', $hash);
        self::assertSame(Command::FAILURE, $this->command('flowcrm:user:create', ['--email' => strtoupper($email), '--display-name' => 'Again'], 'a sufficiently long one')->getStatusCode(), 'unique regardless of case');
    }

    public function testInvalidInputChangesNothing(): void
    {
        $email = 'refused-'.bin2hex(random_bytes(4)).'@example.test';
        $users = $this->db()->fetchOne('SELECT count(*) FROM users');

        $short = $this->command('flowcrm:user:create', ['--email' => $email, '--display-name' => 'Refused'], 'too short');
        self::assertSame(Command::INVALID, $short->getStatusCode());
        self::assertStringContainsString('PASSWORD_TOO_SHORT', $short->getDisplay());
        self::assertStringNotContainsString('too short', str_replace('PASSWORD_TOO_SHORT', '', $short->getDisplay()));
        self::assertSame(Command::INVALID, $this->command('flowcrm:user:create', ['--email' => $email, '--display-name' => 'Refused'])->getStatusCode(), 'no password on standard input');
        self::assertSame(Command::FAILURE, $this->command('flowcrm:user:create', ['--email' => 'not an address', '--display-name' => 'Refused'], 'a sufficiently long one')->getStatusCode());
        self::assertSame(Command::FAILURE, $this->command('flowcrm:organization:create', ['--name' => 'Nobody Ltd', '--admin-email' => $email])->getStatusCode());
        self::assertSame(Command::INVALID, $this->command('flowcrm:membership:add', ['--organization' => 'not-an-id', '--email' => $email, '--role' => 'REP'])->getStatusCode());
        self::assertSame(Command::INVALID, $this->command('flowcrm:membership:add', ['--organization' => '0192f0c4-7d1e-7b8a-9f3c-2b4d6e8f0a1c', '--email' => $email, '--role' => 'OWNER'])->getStatusCode());
        self::assertSame(Command::FAILURE, $this->command('flowcrm:user:enable', ['email' => $email])->getStatusCode());

        self::assertSame($users, $this->db()->fetchOne('SELECT count(*) FROM users'));
    }

    /**
     * A NUL byte never reaches PostgreSQL (pdo_pgsql would cut the bound
     * string there): an address with one, or one that is not UTF-8, names no
     * user, so no command acts on the user whose address it starts with.
     */
    public function testAnAddressWithANulByteOrInvalidUtf8NamesNoUser(): void
    {
        $email = 'nul-'.bin2hex(random_bytes(4)).'@example.test';
        $organization = 'Nul '.bin2hex(random_bytes(4)).' Ltd';
        $this->command('flowcrm:user:create', ['--email' => $email, '--display-name' => 'Nul'], 'a sufficiently long one');
        $before = $this->db()->fetchAssociative('SELECT password_hash, disabled_at FROM users WHERE email = ?', [$email]);
        $users = $this->db()->fetchOne('SELECT count(*) FROM users');

        foreach ([$email."\0", $email."\0x", "\xff".$email] as $spelling) {
            self::assertNotSame(Command::SUCCESS, $this->command('flowcrm:user:reset-password', ['email' => $spelling], 'another long passphrase')->getStatusCode());
            self::assertNotSame(Command::SUCCESS, $this->command('flowcrm:user:disable', ['email' => $spelling])->getStatusCode());
            self::assertNotSame(Command::SUCCESS, $this->command('flowcrm:organization:create', ['--name' => $organization, '--admin-email' => $spelling])->getStatusCode());
            self::assertNotSame(Command::SUCCESS, $this->command('flowcrm:user:create', ['--email' => $spelling, '--display-name' => 'Other'], 'a sufficiently long one')->getStatusCode());
        }

        self::assertSame($before, $this->db()->fetchAssociative('SELECT password_hash, disabled_at FROM users WHERE email = ?', [$email]), 'the user is unchanged');
        self::assertSame($users, $this->db()->fetchOne('SELECT count(*) FROM users'));
        self::assertFalse($this->db()->fetchOne('SELECT 1 FROM organizations WHERE name = ?', [$organization]), 'no organization created');
    }

    public function testAMembershipIsAddedOnceWithItsRole(): void
    {
        $admin = 'admin-'.bin2hex(random_bytes(4)).'@example.test';
        $rep = 'rep-'.bin2hex(random_bytes(4)).'@example.test';
        $this->command('flowcrm:user:create', ['--email' => $admin, '--display-name' => 'Admin'], 'a sufficiently long one');
        $this->command('flowcrm:user:create', ['--email' => $rep, '--display-name' => 'Rep'], 'a sufficiently long one');
        $organization = trim($this->command('flowcrm:organization:create', ['--name' => 'Members Ltd', '--admin-email' => $admin])->getDisplay());

        self::assertSame(Command::SUCCESS, $this->command('flowcrm:membership:add', ['--organization' => $organization, '--email' => $rep, '--role' => 'REP'])->getStatusCode());
        self::assertSame(Command::FAILURE, $this->command('flowcrm:membership:add', ['--organization' => $organization, '--email' => $rep, '--role' => 'ADMIN'])->getStatusCode(), 'one membership per user');

        self::assertSame(
            [['role' => 'ADMIN', 'status' => 'ACTIVE'], ['role' => 'REP', 'status' => 'ACTIVE']],
            $this->db()->fetchAllAssociative('SELECT role, status FROM memberships WHERE organization_id = ? ORDER BY role', [$organization]),
        );
    }

    /** @param array<string, string> $input */
    private function command(string $name, array $input, ?string $stdin = null): CommandTester
    {
        $tester = new CommandTester(new Application(self::bootKernel())->find($name));
        if (null !== $stdin) {
            $tester->setInputs([$stdin]);
        }
        $tester->execute($input, ['interactive' => false]);

        return $tester;
    }

    private function db(): Connection
    {
        $connection = self::getContainer()->get('doctrine.dbal.default_connection');
        \assert($connection instanceof Connection);

        return $connection;
    }
}
