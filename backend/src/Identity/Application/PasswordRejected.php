<?php

declare(strict_types=1);

namespace App\Identity\Application;

/** The new password violates the policy (codes of PasswordPolicy). */
final class PasswordRejected extends \DomainException
{
    /** @param non-empty-list<string> $violations */
    public function __construct(public readonly array $violations)
    {
        parent::__construct('The password does not meet the policy: '.implode(', ', $violations));
    }
}
