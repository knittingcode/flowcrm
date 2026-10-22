<?php

declare(strict_types=1);

namespace App\Tests\Integration\Session;

use App\Tests\Support\Session\FastCgiTimeout;
use App\Tests\Support\Session\FpmServer;
use PHPUnit\Framework\TestCase;

/**
 * The test harness itself: a request that does not answer fails at its
 * deadline instead of hanging the suite, and stopping the server leaves
 * none of its processes behind.
 */
final class FpmServerTest extends TestCase
{
    public function testARequestWithoutAnswerFailsAtItsDeadlineWithDiagnostics(): void
    {
        $fpm = new FpmServer();
        $fpm->start();
        try {
            $start = microtime(true);
            try {
                $fpm->request('POST', '/api/_test/session/increment?pause_ms=2000', timeout: 0.5);
                self::fail('the request outlived its deadline');
            } catch (FastCgiTimeout $e) {
                self::assertLessThan(1.5, microtime(true) - $start);
                self::assertStringContainsString('POST /api/_test/session/increment?pause_ms=2000', $e->getMessage());
                self::assertStringContainsString('PHP-FPM log (tail)', $e->getMessage());
            }
            self::assertSame([], self::childrenNamed('cgi-fcgi'), 'the timed-out client was killed');
            self::assertSame(200, $fpm->request('GET', '/health/live')->status, 'the server still answers');
        } finally {
            $fpm->remove();
        }
    }

    public function testStoppingEndsTheMasterAndEveryWorker(): void
    {
        $fpm = new FpmServer();
        $fpm->start();
        $pids = $fpm->processes();
        self::assertGreaterThanOrEqual(5, \count($pids), 'master and four workers');

        $fpm->remove();

        self::assertSame([], $fpm->processes());
        foreach ($pids as $pid) {
            self::assertFalse(self::running($pid), "PHP-FPM process $pid is still running");
        }
    }

    public function testTheServerRunsInAProcessGroupOfItsOwn(): void
    {
        $fpm = new FpmServer();
        $fpm->start();
        try {
            $pids = $fpm->processes();
            $master = $fpm->master();
            self::assertNotNull($master);
            self::assertContains($master, $pids, 'setsid kept the PID: the master is the process started');
            self::assertSame($master, posix_getpgid($master), 'the master leads its own process group');
            self::assertNotSame(posix_getpgid(0), posix_getpgid($master), 'not the group of the test process');
            foreach ($pids as $pid) {
                self::assertSame($master, posix_getpgid($pid));
            }
        } finally {
            $fpm->remove();
        }
    }

    /**
     * When the master dies on its own (here: killed from outside), its
     * workers get a new parent; they are still found by their process group
     * and pool name and stopped.
     */
    public function testWorkersOfAMasterKilledFromOutsideAreStopped(): void
    {
        $fpm = new FpmServer();
        $fpm->start();
        $master = $fpm->master();
        self::assertNotNull($master);
        $workers = array_values(array_diff($fpm->processes(), [$master]));
        self::assertCount(4, $workers);

        posix_kill($master, 9);
        for ($i = 0; $i < 50 && self::running($master); ++$i) {
            usleep(20_000);
        }
        self::assertSame($workers, $fpm->processes(), 'the orphaned workers are still recognised');

        $fpm->remove();

        foreach ($workers as $pid) {
            self::assertFalse(self::running($pid), "worker $pid is still running");
        }
    }

    /** @return list<int> running children of this PHP process with that command name */
    private static function childrenNamed(string $name): array
    {
        $found = [];
        foreach (glob('/proc/[0-9]*/stat') ?: [] as $stat) {
            $line = (string) @file_get_contents($stat);
            if (preg_match('/^(\d+) \((.*)\) (\S) (\d+) /', $line, $m) && $m[2] === $name && 'Z' !== $m[3] && (int) $m[4] === getmypid()) {
                $found[] = (int) $m[1];
            }
        }

        return $found;
    }

    private static function running(int $pid): bool
    {
        $stat = @file_get_contents('/proc/'.$pid.'/stat');

        return false !== $stat && 1 === preg_match('/\) [^Z]/', $stat);
    }
}
