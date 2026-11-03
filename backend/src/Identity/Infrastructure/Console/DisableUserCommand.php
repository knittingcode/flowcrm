<?php

declare(strict_types=1);

namespace App\Identity\Infrastructure\Console;

use App\Identity\Application\ManageUsers;
use App\Identity\Application\UserNotFound;
use Symfony\Component\Console\Attribute\AsCommand;
use Symfony\Component\Console\Command\Command;
use Symfony\Component\Console\Input\InputArgument;
use Symfony\Component\Console\Input\InputInterface;
use Symfony\Component\Console\Output\OutputInterface;

/**
 * Operator only: a disabled user cannot log in, and every session of the user
 * ends on its next request. Audited as user.disabled.
 */
#[AsCommand(name: 'flowcrm:user:disable', description: 'Disable a user: login fails and every session ends')]
final class DisableUserCommand extends Command
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
        try {
            $this->users->disable(self::text($input->getArgument('email')));
        } catch (UserNotFound|\LogicException $e) {
            $output->writeln('<error>'.$e->getMessage().'</error>');

            return Command::FAILURE;
        }
        $output->writeln('OK: the user is disabled; every session has ended.');

        return Command::SUCCESS;
    }

    private static function text(mixed $value): string
    {
        return \is_string($value) ? $value : '';
    }
}
