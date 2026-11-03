<?php

declare(strict_types=1);

namespace App\Audit\Api;

use Symfony\Component\Uid\Uuid;

/**
 * One audited action. Never put passwords, hashes, tokens, session IDs or
 * personal data values into $changes (FCRM-002 BR-32): name the changed
 * fields or record non-personal values only. No IP address is recorded.
 */
final readonly class AuditRecord
{
    /**
     * @param array<string, scalar|list<scalar>|null> $changes
     */
    public function __construct(
        public string $action,
        public string $entityType,
        public ?Uuid $entityId,
        public Actor $actor,
        public ?Uuid $organizationId = null,
        public array $changes = [],
        public ?Uuid $requestId = null,
    ) {
    }
}
