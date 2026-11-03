<?php

declare(strict_types=1);

namespace App\Tests\Architecture;

use PHPUnit\Framework\Attributes\DataProvider;
use PHPUnit\Framework\TestCase;

/**
 * Proves deptrac.layers.yaml on small source trees: each forbidden
 * dependency is reported, each allowed one is not.
 */
final class LayerRulesTest extends TestCase
{
    /**
     * @return iterable<string, array{array<string, string>, list<string>}>
     */
    public static function cases(): iterable
    {
        $php = ModuleBoundariesTest::php(...);

        yield 'Http -> Application -> Domain, Infrastructure implements Application' => [[
            'CRM/Http/AccountController.php' => $php('App\CRM\Http', 'AccountController', ['App\CRM\Application\CreateAccount', 'Symfony\Component\HttpFoundation\Request', 'Symfony\Component\HttpFoundation\JsonResponse']),
            'CRM/Application/CreateAccount.php' => $php('App\CRM\Application', 'CreateAccount', ['App\CRM\Domain\Account', 'App\CRM\Application\AccountRepository', 'App\Organizations\Api\TenantContext']),
            'CRM/Application/AccountRepository.php' => $php('App\CRM\Application', 'AccountRepository', ['App\CRM\Domain\Account']),
            'CRM/Infrastructure/DoctrineAccountRepository.php' => $php('App\CRM\Infrastructure', 'DoctrineAccountRepository', ['App\CRM\Application\AccountRepository', 'App\CRM\Domain\Account', 'Doctrine\ORM\EntityManagerInterface', 'Doctrine\DBAL\Connection']),
            'CRM/Domain/Account.php' => $php('App\CRM\Domain', 'Account'),
            'Organizations/Api/TenantContext.php' => $php('App\Organizations\Api', 'TenantContext', ['App\Shared\Domain\Uuid']),
            'Shared/Domain/Uuid.php' => $php('App\Shared\Domain', 'Uuid'),
        ], []];
        yield 'Domain uses Doctrine mapping attributes, types and collections' => [[
            'CRM/Domain/Account.php' => "<?php\n\nnamespace App\CRM\Domain;\n\nuse Doctrine\Common\Collections\ArrayCollection;\nuse Doctrine\DBAL\Types\Types;\nuse Doctrine\ORM\Mapping as ORM;\n\n#[ORM\Entity]\nfinal class Account\n{\n    #[ORM\Column(type: Types::STRING)]\n    private string \$name = '';\n\n    public function contacts(): ArrayCollection\n    {\n        return new ArrayCollection();\n    }\n}\n",
        ], []];
        yield 'Domain depends on Infrastructure' => [[
            'CRM/Domain/Account.php' => $php('App\CRM\Domain', 'Account', ['App\CRM\Infrastructure\DoctrineAccountRepository']),
            'CRM/Infrastructure/DoctrineAccountRepository.php' => $php('App\CRM\Infrastructure', 'DoctrineAccountRepository'),
        ], ['Domain on Infrastructure: App\CRM\Domain\Account -> App\CRM\Infrastructure\DoctrineAccountRepository']];
        yield 'Domain depends on Http' => [[
            'CRM/Domain/Account.php' => $php('App\CRM\Domain', 'Account', ['App\CRM\Http\AccountController']),
            'CRM/Http/AccountController.php' => $php('App\CRM\Http', 'AccountController'),
        ], ['Domain on Http: App\CRM\Domain\Account -> App\CRM\Http\AccountController']];
        yield 'Domain depends on Application' => [[
            'CRM/Domain/Account.php' => $php('App\CRM\Domain', 'Account', ['App\CRM\Application\CreateAccount']),
            'CRM/Application/CreateAccount.php' => $php('App\CRM\Application', 'CreateAccount'),
        ], ['Domain on Application: App\CRM\Domain\Account -> App\CRM\Application\CreateAccount']];
        yield 'Domain uses framework HTTP' => [[
            'CRM/Domain/Account.php' => $php('App\CRM\Domain', 'Account', ['Symfony\Component\HttpFoundation\Request']),
        ], ['Domain on HttpFramework: App\CRM\Domain\Account -> Symfony\Component\HttpFoundation\Request']];
        yield 'Domain uses persistence' => [[
            'CRM/Domain/Account.php' => $php('App\CRM\Domain', 'Account', ['Doctrine\ORM\EntityManagerInterface', 'Doctrine\DBAL\Connection']),
        ], [
            'Domain on Persistence: App\CRM\Domain\Account -> Doctrine\DBAL\Connection',
            'Domain on Persistence: App\CRM\Domain\Account -> Doctrine\ORM\EntityManagerInterface',
        ]];
        yield 'Application uses framework HTTP' => [[
            'CRM/Application/CreateAccount.php' => $php('App\CRM\Application', 'CreateAccount', ['Symfony\Component\HttpKernel\Exception\NotFoundHttpException']),
        ], ['Application on HttpFramework: App\CRM\Application\CreateAccount -> Symfony\Component\HttpKernel\Exception\NotFoundHttpException']];
        yield 'Application depends on Http' => [[
            'CRM/Application/CreateAccount.php' => $php('App\CRM\Application', 'CreateAccount', ['App\CRM\Http\AccountRequest']),
            'CRM/Http/AccountRequest.php' => $php('App\CRM\Http', 'AccountRequest'),
        ], ['Application on Http: App\CRM\Application\CreateAccount -> App\CRM\Http\AccountRequest']];
        yield 'Application depends on Infrastructure' => [[
            'CRM/Application/CreateAccount.php' => $php('App\CRM\Application', 'CreateAccount', ['App\CRM\Infrastructure\DoctrineAccountRepository']),
            'CRM/Infrastructure/DoctrineAccountRepository.php' => $php('App\CRM\Infrastructure', 'DoctrineAccountRepository'),
        ], ['Application on Infrastructure: App\CRM\Application\CreateAccount -> App\CRM\Infrastructure\DoctrineAccountRepository']];
        yield 'Http depends on Infrastructure' => [[
            'CRM/Http/AccountController.php' => $php('App\CRM\Http', 'AccountController', ['App\CRM\Infrastructure\DoctrineAccountRepository']),
            'CRM/Infrastructure/DoctrineAccountRepository.php' => $php('App\CRM\Infrastructure', 'DoctrineAccountRepository'),
        ], ['Http on Infrastructure: App\CRM\Http\AccountController -> App\CRM\Infrastructure\DoctrineAccountRepository']];
        yield 'Http uses persistence' => [[
            'CRM/Http/AccountController.php' => $php('App\CRM\Http', 'AccountController', ['Doctrine\DBAL\Connection']),
        ], ['Http on Persistence: App\CRM\Http\AccountController -> Doctrine\DBAL\Connection']];
        yield 'an Api depends on Application' => [[
            'CRM/Api/AccountLookup.php' => $php('App\CRM\Api', 'AccountLookup', ['App\CRM\Application\CreateAccount']),
            'CRM/Application/CreateAccount.php' => $php('App\CRM\Application', 'CreateAccount'),
        ], ['Api on Application: App\CRM\Api\AccountLookup -> App\CRM\Application\CreateAccount']];
        yield 'an Api uses framework HTTP' => [[
            'CRM/Api/AccountLookup.php' => $php('App\CRM\Api', 'AccountLookup', ['Symfony\Component\HttpFoundation\Request']),
        ], ['Api on HttpFramework: App\CRM\Api\AccountLookup -> Symfony\Component\HttpFoundation\Request']];
    }

    /**
     * @param array<string, string> $files
     * @param list<string>          $expected
     */
    #[DataProvider('cases')]
    public function testRule(array $files, array $expected): void
    {
        self::assertSame($expected, Deptrac::violationsIn(Deptrac::LAYERS, $files));
    }
}
