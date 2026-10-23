<?php

declare(strict_types=1);

namespace App\Tests\Support\Session;

/**
 * A real PHP-FPM master serving public/index.php in the test environment,
 * with the image's php.ini, on a free port of 127.0.0.1. Requests go over
 * FastCGI with cgi-fcgi, the client the container health check uses, so
 * the native session storage, the cookie handling of PHP's session module
 * and PdoSessionHandler run exactly as behind the edge.
 *
 * Unsafe requests (POST, PUT, PATCH, DELETE) carry the Origin header a
 * same-origin browser sends (RequestOriginGuard, ADR-019); a test can
 * replace it or, with null, leave it out. A request can have a body.
 *
 * Every request has a deadline: a request still running then is killed
 * (only its own cgi-fcgi process) and reported with diagnostics, so a
 * locking regression fails the test instead of hanging the suite.
 *
 * The master runs in a process group of its own (setsid), with a pool name
 * unique to this server. A process counts as this server's only if it is
 * in that group and its command line names this server's configuration or
 * pool, so workers are still found after the master died and was replaced
 * as their parent. stop() ends them by PID; nothing else is signalled. A
 * shutdown function stops the server even after a fatal error.
 */
final class FpmServer
{
    public const DEFAULT_TIMEOUT = 15.0;
    // Signal numbers (Linux); the image has no pcntl extension for the constants.
    private const SIGQUIT = 3;
    private const SIGKILL = 9;

    /** @var resource|null */
    private $process;
    private ?int $masterPid = null;
    private readonly string $dir;
    private readonly string $poolName;
    private int $port = 0;
    private bool $removed = false;

    /**
     * @param array<string, string> $env  overrides of the container environment
     * @param array<string, string> $pool extra pool directives, such as request_terminate_timeout
     */
    public function __construct(
        private readonly array $env = [],
        private readonly array $pool = [],
    ) {
        $dir = sys_get_temp_dir().'/flowcrm-fpm-'.bin2hex(random_bytes(6));
        if (!mkdir($dir, 0700)) {
            throw new \RuntimeException('cannot create '.$dir);
        }
        $this->dir = $dir;
        $this->poolName = 'probe_'.bin2hex(random_bytes(4));
        register_shutdown_function(function (): void {
            if (!$this->removed) {
                $this->remove();
            }
        });
    }

    public function start(): void
    {
        $this->port = self::freePort();
        $pool = '';
        foreach ($this->pool as $directive => $value) {
            $pool .= "\n{$directive} = {$value}";
        }
        file_put_contents($this->dir.'/fpm.conf', <<<CONF
            [global]
            error_log = {$this->dir}/fpm.log
            log_limit = 16384
            daemonize = no

            [{$this->poolName}]
            listen = 127.0.0.1:{$this->port}
            pm = static
            pm.max_children = 4
            clear_env = no
            catch_workers_output = yes
            decorate_workers_output = no
            CONF.$pool."\n");

        $env = array_merge(getenv(), ['APP_ENV' => 'test', 'APP_DEBUG' => '0'], $this->env);
        $process = proc_open(
            // setsid execs php-fpm in place: the master keeps this PID and leads a new group.
            ['setsid', 'php-fpm', '--nodaemonize', '--fpm-config', $this->dir.'/fpm.conf'],
            [0 => ['file', '/dev/null', 'r'], 1 => ['file', $this->dir.'/fpm.out', 'a'], 2 => ['file', $this->dir.'/fpm.out', 'a']],
            $pipes,
            self::projectDir(),
            $env,
        );
        if (!\is_resource($process)) {
            throw new \RuntimeException('php-fpm did not start');
        }
        $this->process = $process;
        $this->masterPid = proc_get_status($process)['pid'];

        for ($i = 0; $i < 100; ++$i) {
            $socket = @fsockopen('127.0.0.1', $this->port, $errno, $errstr, 0.1);
            if (false !== $socket) {
                fclose($socket);
                // The first request compiles the container; pay for it here.
                $this->request('GET', '/health/live', timeout: 60.0);

                return;
            }
            usleep(100_000);
        }
        $this->stop();
        throw new \RuntimeException('php-fpm is not listening: '.$this->log());
    }

    /**
     * Graceful stop (SIGQUIT): workers finish their requests. After five
     * seconds the master and its workers are killed by PID.
     */
    public function stop(): void
    {
        if (null === $this->process || null === $this->masterPid) {
            return;
        }
        $master = $this->masterPid;
        proc_terminate($this->process, self::SIGQUIT);
        for ($i = 0; $i < 100 && [] !== $this->processes(); ++$i) {
            usleep(50_000);
        }
        $killed = $this->processes();
        foreach ($killed as $pid) {
            posix_kill($pid, self::SIGKILL);
        }
        // Wait for these PIDs, not for processes(): an exiting process loses
        // its command line before it is gone.
        for ($i = 0; $i < 100 && [] !== array_filter($killed, self::isAlive(...)); ++$i) {
            usleep(20_000);
        }
        proc_close($this->process);
        $this->process = null;
        for ($i = 0; $i < 100 && self::isAlive($master); ++$i) {
            usleep(20_000);
        }
        $this->masterPid = null;
    }

    public function restart(): void
    {
        $this->stop();
        $this->start();
    }

    /** The PID of the PHP-FPM master (it also identifies the process group), while started. */
    public function master(): ?int
    {
        return $this->masterPid;
    }

    /**
     * The PIDs of this server's master and workers that are still running:
     * members of its process group whose command line names this server's
     * configuration (master) or pool (workers).
     *
     * @return list<int>
     */
    public function processes(): array
    {
        if (null === $this->masterPid) {
            return [];
        }
        $pids = [];
        foreach (glob('/proc/[0-9]*/stat') ?: [] as $stat) {
            // pid (comm) state ppid pgrp ...; comm may contain spaces, so parse after ')'.
            $line = @file_get_contents($stat);
            if (false === $line || false === ($end = strrpos($line, ')'))) {
                continue;
            }
            $fields = explode(' ', substr($line, $end + 2));
            if ('Z' === $fields[0] || (int) ($fields[2] ?? 0) !== $this->masterPid) {
                continue;
            }
            $pid = (int) basename(\dirname($stat));
            $command = str_replace("\0", ' ', (string) @file_get_contents("/proc/{$pid}/cmdline"));
            if (str_contains($command, $this->dir.'/fpm.conf') || str_contains($command, 'pool '.$this->poolName)) {
                $pids[] = $pid;
            }
        }
        sort($pids);

        return $pids;
    }

    /** Everything the FPM master and its workers wrote (PHP errors included). */
    public function log(): string
    {
        $log = '';
        foreach (['fpm.log', 'fpm.out'] as $file) {
            if (is_file($this->dir.'/'.$file)) {
                $log .= (string) file_get_contents($this->dir.'/'.$file);
            }
        }

        return $log;
    }

    public function remove(): void
    {
        $this->removed = true;
        $this->stop();
        foreach (glob($this->dir.'/*') ?: [] as $file) {
            unlink($file);
        }
        if (is_dir($this->dir)) {
            rmdir($this->dir);
        }
    }

    /**
     * @param array<string, string>      $cookies
     * @param array<string, string|null> $params  extra FastCGI parameters, such as HTTP_X_FORWARDED_PROTO; null leaves one out
     *
     * @throws FastCgiTimeout when no response arrives within $timeout seconds
     */
    public function request(string $method, string $uri, array $cookies = [], bool $https = false, float $timeout = self::DEFAULT_TIMEOUT, array $params = [], ?string $body = null): FastCgiResponse
    {
        return $this->send([$this->begin($method, $uri, $cookies, $https, $params, $body)], $timeout)[0];
    }

    /**
     * Sends the requests at the same time and waits for all of them.
     *
     * @param list<array{0: string, 1: string, 2?: array<string, string>}> $requests method, URI, cookies
     *
     * @return list<FastCgiResponse>
     */
    public function concurrently(array $requests, float $timeout = self::DEFAULT_TIMEOUT): array
    {
        return $this->send(array_map(fn (array $r): array => $this->begin($r[0], $r[1], $r[2] ?? [], false, [], null), $requests), $timeout);
    }

    /**
     * Starts a request and returns at once, so the test can act while it
     * runs (for example while it waits for a database lock); collect()
     * waits for the response.
     *
     * @param array<string, string>      $cookies
     * @param array<string, string|null> $params  extra FastCGI parameters; null leaves one out
     *
     * @return array{process: resource, stdout: resource, label: string}
     */
    public function dispatch(string $method, string $uri, array $cookies = [], array $params = [], ?string $body = null): array
    {
        return $this->begin($method, $uri, $cookies, false, $params, $body);
    }

    /**
     * Waits for requests started with dispatch(), with one deadline for all.
     *
     * @param list<array{process: resource, stdout: resource, label: string}> $started
     *
     * @return list<FastCgiResponse>
     *
     * @throws FastCgiTimeout when a response does not arrive within $timeout seconds
     */
    public function collect(array $started, float $timeout = self::DEFAULT_TIMEOUT): array
    {
        return $this->send($started, $timeout);
    }

    /**
     * @param array<string, string>      $cookies
     * @param array<string, string|null> $extra
     *
     * @return array{process: resource, stdout: resource, label: string}
     */
    private function begin(string $method, string $uri, array $cookies, bool $https, array $extra, ?string $body): array
    {
        $query = (string) parse_url($uri, \PHP_URL_QUERY);
        $params = [
            'GATEWAY_INTERFACE' => 'CGI/1.1',
            'SERVER_PROTOCOL' => 'HTTP/1.1',
            'SERVER_NAME' => 'localhost',
            'SERVER_PORT' => $https ? '443' : '80',
            'REMOTE_ADDR' => '127.0.0.1',
            'REQUEST_METHOD' => $method,
            'REQUEST_URI' => $uri,
            'QUERY_STRING' => $query,
            'SCRIPT_NAME' => '/index.php',
            'SCRIPT_FILENAME' => self::projectDir().'/public/index.php',
            'DOCUMENT_ROOT' => self::projectDir().'/public',
            'CONTENT_LENGTH' => (string) \strlen($body ?? ''),
            'HTTP_HOST' => 'localhost',
            'HTTP_ACCEPT' => 'application/json',
        ];
        if (!\in_array($method, ['GET', 'HEAD', 'OPTIONS', 'TRACE'], true)) {
            $params['HTTP_ORIGIN'] = ($https ? 'https' : 'http').'://localhost';
        }
        if ($https) {
            $params['HTTPS'] = 'on';
        }
        if ([] !== $cookies) {
            $params['HTTP_COOKIE'] = implode('; ', array_map(
                static fn (string $name, string $value): string => $name.'='.$value,
                array_keys($cookies),
                $cookies,
            ));
        }

        // cgi-fcgi sends its whole environment as the FastCGI parameters and
        // its standard input as the request body.
        $process = proc_open(
            ['cgi-fcgi', '-bind', '-connect', '127.0.0.1:'.$this->port],
            [0 => null === $body ? ['file', '/dev/null', 'r'] : ['pipe', 'r'], 1 => ['pipe', 'w'], 2 => ['file', '/dev/null', 'w']],
            $pipes,
            null,
            array_filter(array_merge($params, $extra), static fn (?string $value): bool => null !== $value),
        );
        if (!\is_resource($process)) {
            throw new \RuntimeException('cgi-fcgi did not start');
        }
        if (null !== $body) {
            fwrite($pipes[0], $body);
            fclose($pipes[0]);
        }
        stream_set_blocking($pipes[1], false);

        return ['process' => $process, 'stdout' => $pipes[1], 'label' => $method.' '.$uri];
    }

    /**
     * Reads every response until the shared deadline. On a timeout, the
     * cgi-fcgi processes of this call are killed and FastCgiTimeout tells
     * which requests were still running.
     *
     * @param list<array{process: resource, stdout: resource, label: string}> $started
     *
     * @return list<FastCgiResponse>
     */
    private function send(array $started, float $timeout): array
    {
        $start = microtime(true);
        $deadline = $start + $timeout;
        $output = array_fill(0, \count($started), '');
        $open = array_keys($started);
        while ([] !== $open) {
            $remaining = $deadline - microtime(true);
            if ($remaining <= 0) {
                $pending = [];
                foreach ($open as $i) {
                    $pending[] = $started[$i]['label'];
                }
                foreach ($started as $request) {
                    proc_terminate($request['process'], self::SIGKILL);
                    fclose($request['stdout']);
                    proc_close($request['process']);
                }
                throw new FastCgiTimeout(\sprintf("no response after %.1f s for: %s\nPHP-FPM log (tail):\n%s", microtime(true) - $start, implode(', ', $pending), substr($this->log(), -2000)));
            }
            $read = [];
            foreach ($open as $i) {
                $read[] = $started[$i]['stdout'];
            }
            $write = $except = null;
            if (false === stream_select($read, $write, $except, (int) $remaining, (int) (fmod($remaining, 1.0) * 1_000_000))) {
                throw new \RuntimeException('stream_select failed');
            }
            foreach ($open as $k => $i) {
                $chunk = fread($started[$i]['stdout'], 65536);
                if (false !== $chunk) {
                    $output[$i] .= $chunk;
                }
                if (feof($started[$i]['stdout'])) {
                    unset($open[$k]);
                }
            }
        }

        $responses = [];
        foreach ($started as $i => $request) {
            fclose($request['stdout']);
            $exit = proc_close($request['process']);
            if (0 !== $exit) {
                throw new \RuntimeException(\sprintf("cgi-fcgi exited with %d for %s\nPHP-FPM log (tail):\n%s", $exit, $request['label'], substr($this->log(), -2000)));
            }
            $responses[] = FastCgiResponse::parse($output[$i]);
        }

        return $responses;
    }

    /** The backend this test code belongs to: /app, or a copy (tests/Mutation). */
    private static function projectDir(): string
    {
        return \dirname(__DIR__, 3);
    }

    private static function isAlive(int $pid): bool
    {
        $stat = @file_get_contents('/proc/'.$pid.'/stat');
        if (false === $stat || false === ($end = strrpos($stat, ')'))) {
            return false;
        }

        return 'Z' !== substr($stat, $end + 2, 1);
    }

    private static function freePort(): int
    {
        $server = stream_socket_server('tcp://127.0.0.1:0');
        if (false === $server) {
            throw new \RuntimeException('no free port');
        }
        $name = (string) stream_socket_get_name($server, false);
        fclose($server);

        return (int) substr($name, (int) strrpos($name, ':') + 1);
    }
}
