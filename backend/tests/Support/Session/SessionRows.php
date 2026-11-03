<?php

declare(strict_types=1);

namespace App\Tests\Support\Session;

use Doctrine\DBAL\Connection;
use PHPUnit\Framework\Assert;

/**
 * Counts rows of the sessions table across one test, independent of
 * session garbage collection.
 *
 * Every request that starts a session runs the garbage collection with a
 * probability of 1/100 (config/packages/session.yaml), and it deletes every
 * row whose expiry (sess_lifetime) has passed, including rows that earlier
 * tests left behind. A plain count(*) can therefore drop between two reads
 * of one test although the code under test wrote or deleted nothing.
 *
 * A snapshot fixes a horizon when it is taken and counts only rows that
 * expire at or after it: the garbage collection cannot delete them while
 * the test runs (shorter than HORIZON_SECONDS), and every row written
 * during the test expires after the idle lifetime of 1800 s (asserted by
 * FpmSessionTest and SessionAndCacheConfigurationTest), so it is counted.
 */
final class SessionRows
{
    /** Longer than any test, shorter than the idle lifetime of 1800 s. */
    private const HORIZON_SECONDS = 600;

    private function __construct(
        private readonly Connection $db,
        private readonly int $horizon,
    ) {
    }

    public static function snapshot(Connection $db): self
    {
        return new self($db, time() + self::HORIZON_SECONDS);
    }

    /** Rows that expire at or after the horizon of this snapshot. */
    public function count(): int
    {
        $count = $this->db->fetchOne('SELECT count(*) FROM sessions WHERE sess_lifetime >= ?', [$this->horizon]);
        Assert::assertIsInt($count);

        return $count;
    }
}
