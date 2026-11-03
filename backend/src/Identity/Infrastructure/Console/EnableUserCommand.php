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
 * Operator only: the user can log in again. Audited as user.enabled.
 */
#[AsCommand(name: 'flowcrm:user:enable', description: 'Enable a disabled user again')]
final class EnableUserCommand extends Command
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
            $this->users->enable(self::text($input->getArgument('email')));
        } catch (UserNotFound|\LogicException $e) {
            $output->writeln('<error>'.$e->getMessage().'</error>');

            return Command::FAILURE;
        }
        $output->writeln('OK: the user is enabled.');

        return Command::SUCCESS;
    }

    private static function text(mixed $value): string
    {
        return \is_string($value) ? $value : '';
    }
}
