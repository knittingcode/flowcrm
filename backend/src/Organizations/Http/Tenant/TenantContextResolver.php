<?php

declare(strict_types=1);

namespace App\Organizations\Http\Tenant;

use App\Organizations\Api\TenantContext;
use Symfony\Component\HttpFoundation\Request;
use Symfony\Component\HttpKernel\Controller\ValueResolverInterface;
use Symfony\Component\HttpKernel\ControllerMetadata\ArgumentMetadata;

/** Passes the TenantContext resolved by TenantGuard to a controller argument. */
final readonly class TenantContextResolver implements ValueResolverInterface
{
    /** @return iterable<TenantContext> */
    public function resolve(Request $request, ArgumentMetadata $argument): iterable
    {
        if (TenantContext::class !== $argument->getType()) {
            return [];
        }
        $context = $request->attributes->get(TenantContext::ATTRIBUTE);
        if (!$context instanceof TenantContext) {
            throw new \LogicException('No tenant context: only tenant routes can take one.');
        }

        return [$context];
    }
}
