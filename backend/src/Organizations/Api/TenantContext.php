<?php

declare(strict_types=1);

namespace App\Organizations\Api;

use Symfony\Component\Uid\Uuid;

/**
 * The organization of the current request and the current user's active
 * membership in it, resolved from the route on every request (TenantGuard).
 * Never stored in the session and never taken from client input other than
 * the validated route identifier (FCRM-002 TI-05).
 */
final readonly class TenantContext
{
    public const ATTRIBUTE = '_tenant_context';

    public function __construct(
        public Uuid $organizationId,
        public Uuid $membershipId,
        public Uuid $userId,
        /** ADMIN, MANAGER or REP */
        public string $role,
    ) {
    }
}
