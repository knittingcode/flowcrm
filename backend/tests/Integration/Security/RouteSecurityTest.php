<?php

declare(strict_types=1);

namespace App\Tests\Integration\Security;

use App\Organizations\Http\Tenant\TenantPermission;
use App\Tests\Support\Http\OpenApiContract;
use Symfony\Bundle\FrameworkBundle\Test\KernelTestCase;
use Symfony\Bundle\SecurityBundle\Security\FirewallMap;
use Symfony\Component\HttpFoundation\Request;
use Symfony\Component\Routing\Requirement\Requirement;
use Symfony\Component\Routing\Route;
use Symfony\Component\Routing\RouterInterface;
use Symfony\Component\Security\Http\AccessMapInterface;

/**
 * Deny by default, checked over every registered route (FCRM-002 NFR-002,
 * FCRM-003 FND-009 "route registry test"): a new route that forgets its
 * policy fails here before it can be released.
 */
final class RouteSecurityTest extends KernelTestCase
{
    /** The only API routes that anonymous visitors may call. */
    private const PUBLIC = [
        'api_v1_system_status',
        'api_v1_auth_session',
        'api_v1_auth_login',
        'api_v1_auth_logout',
    ];

    public function testEveryTenantRouteHasAValidatedOrganizationAndExactlyOnePermission(): void
    {
        $tenantRoutes = 0;
        foreach ($this->apiRoutes() as $name => $route) {
            $path = $route->getPath();
            if (!str_starts_with($path, '/api/v1/organizations')) {
                self::assertStringNotContainsString('{organizationId}', $path, $name);
                self::assertSame([], $this->permissions($route), "$name: TenantPermission outside a tenant route");
                continue;
            }
            ++$tenantRoutes;
            self::assertStringStartsWith('/api/v1/organizations/{organizationId}', $path, "$name: no organization data without a tenant");
            self::assertSame(Requirement::UUID, $route->getRequirement('organizationId'), $name);
            self::assertCount(1, $this->permissions($route), "$name must declare exactly one TenantPermission");
        }
        self::assertGreaterThanOrEqual(3, $tenantRoutes);
    }

    public function testEveryApiRouteOutsideThePublicListNeedsALogin(): void
    {
        $container = self::getContainer();
        $accessMap = $container->get('security.access_map');
        $firewalls = $container->get('security.firewall.map');
        \assert($accessMap instanceof AccessMapInterface && $firewalls instanceof FirewallMap);

        foreach ($this->apiRoutes() as $name => $route) {
            $request = Request::create(self::samplePath($route), $route->getMethods()[0] ?? 'GET');
            [$attributes] = $accessMap->getPatterns($request);
            $expected = \in_array($name, self::PUBLIC, true) || str_starts_with($route->getPath(), '/api/_test/') ? ['PUBLIC_ACCESS'] : ['IS_AUTHENTICATED'];
            self::assertSame($expected, $attributes, $name);
            self::assertSame('api', $firewalls->getFirewallConfig($request)?->getName(), "$name is behind the api firewall");
        }
        foreach (['/health/live', '/health/ready'] as $path) {
            self::assertNotSame('api', $firewalls->getFirewallConfig(Request::create($path))?->getName(), "$path never reads a session");
        }
    }

    /** The committed specification describes exactly the API v1 routes, and it is valid. */
    public function testTheSpecificationDescribesExactlyTheApiRoutes(): void
    {
        $spec = OpenApiContract::spec();
        self::assertTrue($spec->validate(), implode("\n", $spec->getErrors()));

        $documented = [];
        foreach ($spec->paths as $path => $item) {
            self::assertIsString($path);
            foreach (array_keys($item->getOperations()) as $method) {
                $documented[] = strtoupper($method).' '.$path;
            }
        }
        $implemented = [];
        foreach ($this->apiRoutes() as $route) {
            if (str_starts_with($route->getPath(), '/api/v1/')) {
                foreach ($route->getMethods() as $method) {
                    $implemented[] = $method.' '.$route->getPath();
                }
            }
        }
        sort($documented);
        sort($implemented);

        self::assertSame($implemented, $documented);
    }

    /** @return array<string, Route> */
    private function apiRoutes(): array
    {
        $router = self::getContainer()->get('router');
        \assert($router instanceof RouterInterface);

        return array_filter($router->getRouteCollection()->all(), static fn (Route $route): bool => str_starts_with($route->getPath(), '/api/'));
    }

    /** @return list<\ReflectionAttribute<TenantPermission>> */
    private function permissions(Route $route): array
    {
        $controller = $route->getDefault('_controller');
        self::assertIsString($controller);
        [$class, $method] = explode('::', $controller, 2) + [1 => '__invoke'];
        \assert(class_exists($class));

        return new \ReflectionMethod($class, $method)->getAttributes(TenantPermission::class);
    }

    private static function samplePath(Route $route): string
    {
        return (string) preg_replace('/\{[^}]+\}/', '0192f0c4-7d1e-7b8a-9f3c-2b4d6e8f0a1c', $route->getPath());
    }
}
