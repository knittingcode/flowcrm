<?php

declare(strict_types=1);

namespace App\Shared\Infrastructure\Database;

use Symfony\Component\Console\Attribute\AsCommand;
use Symfony\Component\Console\Command\Command;
use Symfony\Component\Console\Input\InputInterface;
use Symfony\Component\Console\Input\InputOption;
use Symfony\Component\Console\Output\OutputInterface;

/**
 * Fails unless the database matches the runtime privilege manifest
 * (RuntimePrivileges). With --runtime it also fails unless the connection
 * itself uses flowcrm_app, the role the API must run as. Run by make up
 * after the migrations; a failure stops the start (fail closed).
 */
#[AsCommand(name: 'app:database:verify-privileges', description: 'Verify the database roles and runtime privileges (ADR-018)')]
final class VerifyPrivilegesCommand extends Command
{
    public function __construct(private readonly RuntimePrivileges $privileges)
    {
        parent::__construct();
    }

    protected function configure(): void
    {
        $this->addOption('runtime', null, InputOption::VALUE_NONE, 'Also require this connection to use '.RuntimePrivileges::RUNTIME);
    }

    protected function execute(InputInterface $input, OutputInterface $output): int
    {
        $violations = $this->privileges->violations();
        if (true === $input->getOption('runtime') && RuntimePrivileges::RUNTIME !== ($role = $this->privileges->currentRole())) {
            $violations[] = \sprintf('this connection uses %s, not %s', $role, RuntimePrivileges::RUNTIME);
        }
        if ([] === $violations) {
            $output->writeln('OK: the database roles and runtime privileges match config/database/runtime-privileges.yaml');

            return Command::SUCCESS;
        }
        foreach ($violations as $violation) {
            $output->writeln('VIOLATION: '.$violation);
        }

        return Command::FAILURE;
    }
}
