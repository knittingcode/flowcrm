<?php

declare(strict_types=1);

namespace App\Tests\Architecture;

use PHPUnit\Framework\Attributes\DataProvider;
use PHPUnit\Framework\TestCase;

/**
 * Proves deptrac.modules.yaml on small source trees: each forbidden
 * dependency is reported, each allowed one is not.
 */
final class ModuleBoundariesTest extends TestCase
{
    /**
     * @return iterable<string, array{array<string, string>, list<string>}>
     */
    public static function cases(): iterable
    {
        yield 'a module uses the Api of another module and Shared' => [[
            'Sales/Application/CreateOpportunity.php' => self::php('App\Sales\Application', 'CreateOpportunity', ['App\CRM\Api\AccountLookup', 'App\Shared\Domain\Money']),
            'CRM/Api/AccountLookup.php' => self::php('App\CRM\Api', 'AccountLookup'),
            'Shared/Domain/Money.php' => self::php('App\Shared\Domain', 'Money'),
        ], []];
        yield 'a module uses its own layers' => [[
            'CRM/Http/AccountController.php' => self::php('App\CRM\Http', 'AccountController', ['App\CRM\Application\CreateAccount', 'App\CRM\Api\AccountLookup']),
            'CRM/Application/CreateAccount.php' => self::php('App\CRM\Application', 'CreateAccount'),
            'CRM/Api/AccountLookup.php' => self::php('App\CRM\Api', 'AccountLookup'),
        ], []];
        yield 'a module uses the internals of another module' => [[
            'Sales/Application/CreateOpportunity.php' => self::php('App\Sales\Application', 'CreateOpportunity', ['App\CRM\Domain\Account']),
            'CRM/Domain/Account.php' => self::php('App\CRM\Domain', 'Account'),
        ], ['Sales on CRM: App\Sales\Application\CreateOpportunity -> App\CRM\Domain\Account']];
        yield 'an Api exposes the internals of its module' => [[
            'CRM/Api/AccountLookup.php' => self::php('App\CRM\Api', 'AccountLookup', ['App\CRM\Domain\Account']),
            'CRM/Domain/Account.php' => self::php('App\CRM\Domain', 'Account'),
        ], ['CRMApi on CRM: App\CRM\Api\AccountLookup -> App\CRM\Domain\Account']];
        yield 'an Api depends on another Api' => [[
            'Sales/Api/OpportunityLookup.php' => self::php('App\Sales\Api', 'OpportunityLookup', ['App\CRM\Api\AccountLookup']),
            'CRM/Api/AccountLookup.php' => self::php('App\CRM\Api', 'AccountLookup'),
        ], ['SalesApi on CRMApi: App\Sales\Api\OpportunityLookup -> App\CRM\Api\AccountLookup']];
        yield 'Shared depends on a module' => [[
            'Shared/Http/Listener.php' => self::php('App\Shared\Http', 'Listener', ['App\Organizations\Api\TenantContext']),
            'Organizations/Api/TenantContext.php' => self::php('App\Organizations\Api', 'TenantContext'),
        ], ['Shared on OrganizationsApi: App\Shared\Http\Listener -> App\Organizations\Api\TenantContext']];
    }

    /**
     * @param array<string, string> $files
     * @param list<string>          $expected
     */
    #[DataProvider('cases')]
    public function testRule(array $files, array $expected): void
    {
        self::assertSame($expected, Deptrac::violationsIn(Deptrac::MODULES, $files));
    }

    /**
     * A class that uses each of $uses in a method signature.
     *
     * @param list<string> $uses
     */
    public static function php(string $namespace, string $class, array $uses = []): string
    {
        $parameters = [];
        foreach ($uses as $i => $use) {
            $parameters[] = '\\'.$use.' $p'.$i;
        }

        return \sprintf("<?php\n\nnamespace %s;\n\nfinal class %s\n{\n    public function use(%s): void\n    {\n    }\n}\n", $namespace, $class, implode(', ', $parameters));
    }
}
