<?php

declare(strict_types=1);

namespace App\Organizations\Infrastructure\Console;

use App\Organizations\Application\ManageOrganizations;
use App\Organizations\Domain\MembershipRole;
use Symfony\Component\Console\Attribute\AsCommand;
use Symfony\Component\Console\Command\Command;
use Symfony\Component\Console\Input\InputInterface;
use Symfony\Component\Console\Input\InputOption;
use Symfony\Component\Console\Output\OutputInterface;
use Symfony\Component\Uid\Uuid;

/**
 * Operator only, for reproducible demonstration and test setups (several
 * roles, one user in two organizations). Audited as membership.added.
 */
#[AsCommand(name: 'flowcrm:membership:add', description: 'Add an existing user to an organization with a role')]
final class AddMembershipCommand extends Command
{
    public function __construct(private readonly ManageOrganizations $organizations)
    {
        parent::__construct();
    }

    protected function configure(): void
    {
        $this
            ->addOption('organization', null, InputOption::VALUE_REQUIRED, 'Organization ID')
            ->addOption('email', null, InputOption::VALUE_REQUIRED, 'E-mail address of the existing user')
            ->addOption('role', null, InputOption::VALUE_REQUIRED, 'ADMIN, MANAGER or REP');
    }

    protected function execute(InputInterface $input, OutputInterface $output): int
    {
        $organization = self::text($input->getOption('organization'));
        $email = $input->getOption('email');
        $role = MembershipRole::tryFrom(self::text($input->getOption('role')));
        if (!Uuid::isValid($organization) || !\is_string($email) || null === $role) {
            $output->writeln('<error>--organization (an ID), --email and --role (ADMIN, MANAGER or REP) are required.</error>');

            return Command::INVALID;
        }

        try {
            $id = $this->organizations->addMember(Uuid::fromString($organization), $email, $role);
        } catch (\InvalidArgumentException $e) {
            $output->writeln('<error>'.$e->getMessage().'</error>');

            return Command::FAILURE;
        }
        $output->writeln($id->toRfc4122());

        return Command::SUCCESS;
    }

    private static function text(mixed $value): string
    {
        return \is_string($value) ? $value : '';
    }
}
