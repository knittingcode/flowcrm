<?php

declare(strict_types=1);

namespace App\Identity\Infrastructure\Console;

use App\Identity\Application\EmailTaken;
use App\Identity\Application\ManageUsers;
use App\Identity\Application\PasswordRejected;
use Symfony\Component\Console\Attribute\AsCommand;
use Symfony\Component\Console\Command\Command;
use Symfony\Component\Console\Input\InputInterface;
use Symfony\Component\Console\Input\InputOption;
use Symfony\Component\Console\Output\OutputInterface;

/** Operator only (FCRM-002: no public registration); audited as user.created. */
#[AsCommand(name: 'flowcrm:user:create', description: 'Create a user; the password is read from standard input')]
final class CreateUserCommand extends Command
{
    public function __construct(private readonly ManageUsers $users)
    {
        parent::__construct();
    }

    protected function configure(): void
    {
        $this
            ->addOption('email', null, InputOption::VALUE_REQUIRED, 'E-mail address (unique regardless of case)')
            ->addOption('display-name', null, InputOption::VALUE_REQUIRED, 'Name shown to other members');
    }

    protected function execute(InputInterface $input, OutputInterface $output): int
    {
        $email = $input->getOption('email');
        $displayName = $input->getOption('display-name');
        if (!\is_string($email) || !\is_string($displayName)) {
            $output->writeln('<error>--email and --display-name are required.</error>');

            return Command::INVALID;
        }
        $password = PasswordInput::read($input, $output);
        if (null === $password) {
            $output->writeln('<error>No password on standard input.</error>');

            return Command::INVALID;
        }

        try {
            $id = $this->users->create($email, $displayName, $password);
        } catch (PasswordRejected $e) {
            $output->writeln('<error>The password was rejected: '.implode(', ', $e->violations).'</error>');

            return Command::INVALID;
        } catch (EmailTaken|\InvalidArgumentException $e) {
            $output->writeln('<error>'.$e->getMessage().'</error>');

            return Command::FAILURE;
        }
        $output->writeln($id->toRfc4122());

        return Command::SUCCESS;
    }
}
