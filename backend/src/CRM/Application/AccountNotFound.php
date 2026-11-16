<?php

declare(strict_types=1);

namespace App\CRM\Application;

/** No such account in this organization (also for an account of another organization). */
final class AccountNotFound extends \RuntimeException
{
}
