<?php

declare(strict_types=1);

namespace App\Audit\Api;

/**
 * The append-only audit log. record() writes immediately; inside an open
 * transaction the event commits or rolls back with the audited change.
 */
interface AuditTrail
{
    public function record(AuditRecord $record): void;
}
