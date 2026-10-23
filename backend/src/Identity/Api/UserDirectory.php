<?php

declare(strict_types=1);

namespace App\Identity\Api;

use Symfony\Component\Uid\Uuid;

/** Read access to users for other modules (by ID; no credentials). */
interface UserDirectory
{
    /**
     * @param list<Uuid> $ids
     *
     * @return array<string, UserProfile> keyed by the RFC 4122 form of the ID; unknown IDs are missing
     */
    public function profiles(array $ids): array;

    /** Case-insensitive lookup, for the operator console. */
    public function idOfEmail(string $email): ?Uuid;
}
