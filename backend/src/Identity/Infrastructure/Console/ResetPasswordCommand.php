<?php

declare(strict_types=1);

namespace App\Identity\Infrastructure\Console;

use App\Identity\Application\ManageUsers;
use App\Identity\Application\PasswordRejected;
use App\Identity\Application\UserNotFound;
use Symfony\Component\Console\Attribute\AsCommand;
use Symfony\Component\Console\Command\Command;
use Symfony\Component\Console\Input\InputArgument;
use Symfony\Component\Console\Input\InputInterface;
use Symfony\Component\Console\Output\OutputInterface;

/**
 * Operator-assisted account recovery without e-mail (FCRM-002 OQ-10): sets a
 * new password, which ends every session of the user. Audited as
 * user.password_reset.
 */
#[AsCommand(name: 'flowcrm:user:reset-password', description: 'Set a new password for a user; it is read from standard input')]
final class ResetPasswordCommand extends Command
{
    public function __construct(private readonly ManageUsers $users)
    {
        parent::__construct();
    }

    protected function configure(): void
    {
        $this->addArgument('email', InputArgument::REQUIRED, 'E-mail address of the user');
    }

    protected function execute(InputInterface $input, OutputInterface $output): int
    {
        $email = self::text($input->getArgument('email'));
        $password = PasswordInput::read($input, $output);
        if (null === $password) {
            $output->writeln('<error>No password on standard input.</error>');

            return Command::INVALID;
        }

        try {
            $this->users->resetPassword($email, $password);
        } catch (PasswordRejected $e) {
            $output->writeln('<error>The password was rejected: '.implode(', ', $e->violations).'</error>');

            return Command::INVALID;
        } catch (UserNotFound $e) {
            $output->writeln('<error>'.$e->getMessage().'</error>');

            return Command::FAILURE;
        }
        $output->writeln('OK: the password was changed; every session of the user has ended.');

        return Command::SUCCESS;
    }

    private static function text(mixed $value): string
    {
        return \is_string($value) ? $value : '';
    }
}
