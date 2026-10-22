<?php

declare(strict_types=1);

namespace App\Tests\Support\Session;

/**
 * A FastCGI request of FpmServer got no response before its deadline.
 */
final class FastCgiTimeout extends \RuntimeException
{
}
