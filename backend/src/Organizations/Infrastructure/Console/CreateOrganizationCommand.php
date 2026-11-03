<?php

declare(strict_types=1);

namespace App\Organizations\Infrastructure\Console;

use App\Organizations\Application\ManageOrganizations;
use App\Organizations\Domain\Currency;
use Symfony\Component\Console\Attribute\AsCommand;
use Symfony\Component\Console\Command\Command;
use Symfony\Component\Console\Input\InputInterface;
use Symfony\Component\Console\Input\InputOption;
use Symfony\Component\Console\Output\OutputInterface;

/** Operator only: an organization with its first ADMIN (an existing user). Audited. */
#[AsCommand(name: 'flowcrm:organization:create', description: 'Create an organization with its first administrator')]
final class CreateOrganizationCommand extends Command
{
    public function __construct(private readonly ManageOrganizations $organizations)
    {
        parent::__construct();
    }

    protected function configure(): void
    {
        $this
            ->addOption('name', null, InputOption::VALUE_REQUIRED, 'Organization name')
            ->addOption('currency', null, InputOption::VALUE_REQUIRED, 'Currency ('.implode(', ', array_map(static fn (Currency $c): string => $c->value, Currency::cases())).')', 'EUR')
            ->addOption('timezone', null, InputOption::VALUE_REQUIRED, 'IANA timezone', 'Europe/Warsaw')
            ->addOption('admin-email', null, InputOption::VALUE_REQUIRED, 'E-mail address of the existing user who becomes ADMIN');
    }

    protected function execute(InputInterface $input, OutputInterface $output): int
    {
        $name = $input->getOption('name');
        $currency = Currency::tryFrom(self::text($input->getOption('currency')));
        $timezone = $input->getOption('timezone');
        $admin = $input->getOption('admin-email');
        if (!\is_string($name) || null === $currency || !\is_string($timezone) || !\is_string($admin)) {
            $output->writeln('<error>--name, --admin-email and a supported --currency are required.</error>');

            return Command::INVALID;
        }

        try {
            $id = $this->organizations->create($name, $currency, $timezone, $admin);
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
