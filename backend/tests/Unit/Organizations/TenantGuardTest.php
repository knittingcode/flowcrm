<?php

declare(strict_types=1);

namespace App\Tests\Unit\Organizations;

use App\Identity\Api\CurrentUser;
use App\Organizations\Api\TenantContext;
use App\Organizations\Application\OrganizationReadModel;
use App\Organizations\Http\Tenant\TenantGuard;
use App\Shared\Http\Problem\ProblemException;
use App\Tests\Support\Fixture\TenantControllers;
use PHPUnit\Framework\TestCase;
use Psr\Log\NullLogger;
use Symfony\Component\HttpFoundation\Request;
use Symfony\Component\HttpKernel\Event\ControllerEvent;
use Symfony\Component\HttpKernel\HttpKernelInterface;
use Symfony\Component\Security\Core\Authorization\AuthorizationCheckerInterface;
use Symfony\Component\Uid\Uuid;

final class TenantGuardTest extends TestCase
{
    private Uuid $user;

    protected function setUp(): void
    {
        $this->user = Uuid::v7();
    }

    public function testATenantRouteWithoutAPermissionFailsClosed(): void
    {
        $this->expectException(\LogicException::class);
        $this->expectExceptionMessage('must declare exactly one TenantPermission');

        $this->guard(membership: true, granted: true)($this->event('undeclared', Uuid::v7()->toRfc4122()));
    }

    public function testTwoPermissionsAreRefusedToo(): void
    {
        $this->expectException(\LogicException::class);

        $this->guard(membership: true, granted: true)($this->event('twice', Uuid::v7()->toRfc4122()));
    }

    public function testAPermissionOnARouteWithoutTenantIsAMistake(): void
    {
        $this->expectException(\LogicException::class);

        $this->guard(membership: true, granted: true)($this->event('declared', null));
    }

    public function testNoActiveMembershipIsNotFound(): void
    {
        $this->assertProblem(404, fn () => $this->guard(membership: false, granted: true)($this->event('declared', Uuid::v7()->toRfc4122())));
        $this->assertProblem(404, fn () => $this->guard(membership: true, granted: true)($this->event('declared', 'not-a-uuid')));
    }

    public function testAMissingPermissionIsForbiddenAndAGrantedOneSetsTheContext(): void
    {
        $this->assertProblem(403, fn () => $this->guard(membership: true, granted: false)($this->event('declared', Uuid::v7()->toRfc4122())));

        $event = $this->event('declared', Uuid::v7()->toRfc4122());
        $this->guard(membership: true, granted: true)($event);
        self::assertInstanceOf(TenantContext::class, $event->getRequest()->attributes->get(TenantContext::ATTRIBUTE));
    }

    public function testRoutesWithoutTenantAreLeftAlone(): void
    {
        $event = $this->event('undeclared', null);
        $this->guard(membership: false, granted: false)($event);

        self::assertFalse($event->getRequest()->attributes->has(TenantContext::ATTRIBUTE));
    }

    private function assertProblem(int $status, \Closure $call): void
    {
        try {
            $call();
            self::fail('no problem raised');
        } catch (ProblemException $e) {
            self::assertSame($status, $e->getStatusCode());
        }
    }

    private function guard(bool $membership, bool $granted): TenantGuard
    {
        $organizations = $this->createStub(OrganizationReadModel::class);
        $organizations->method('activeMembership')->willReturnCallback(fn (Uuid $org, Uuid $user): ?TenantContext => $membership ? new TenantContext($org, Uuid::v7(), $user, 'REP') : null);
        $currentUser = $this->createStub(CurrentUser::class);
        $currentUser->method('id')->willReturn($this->user);
        $authorization = $this->createStub(AuthorizationCheckerInterface::class);
        $authorization->method('isGranted')->willReturn($granted);

        return new TenantGuard($organizations, $currentUser, $authorization, new NullLogger());
    }

    private function event(string $method, ?string $organizationId): ControllerEvent
    {
        $request = Request::create('/api/v1/x');
        $request->attributes->set('_route', 'fixture');
        $request->attributes->set('_route_params', null === $organizationId ? [] : ['organizationId' => $organizationId]);

        $controller = [new TenantControllers(), $method];
        \assert(\is_callable($controller));

        return new ControllerEvent($this->createStub(HttpKernelInterface::class), $controller, $request, HttpKernelInterface::MAIN_REQUEST);
    }
}
