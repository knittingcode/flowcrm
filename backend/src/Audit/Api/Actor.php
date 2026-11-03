<?php

declare(strict_types=1);

namespace App\Audit\Api;

use Symfony\Component\Uid\Uuid;

/** Who performed an audited action (the actor_type values of audit_events). */
final readonly class Actor
{
    private function __construct(
        public string $type,
        public ?Uuid $userId,
        public ?string $role,
    ) {
    }

    /** A logged-in user; the role is the organization role, when the action is tenant-scoped. */
    public static function user(Uuid $userId, ?string $role = null): self
    {
        return new self('user', $userId, $role);
    }

    /** The platform operator, through the console (no user account). */
    public static function operator(): self
    {
        return new self('platform_operator', null, null);
    }
}
