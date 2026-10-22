<?php

declare(strict_types=1);

namespace App\Tests\Support\Session;

/**
 * A real PHP-FPM master serving public/index.php in the test environment,
 * with the image's php.ini, on a free port of 127.0.0.1. Requests go over
 * FastCGI with cgi-fcgi, the client the container health check uses, so
 * the native session storage, the cookie handling of PHP's session module
 * and PdoSessionHandler run exactly as behind the edge.
 */
final class FpmServer
{
    private const DOCUMENT_ROOT = '/app/public';
    // Signal numbers (Linux); the image has no pcntl extension for the constants.
    private const SIGQUIT = 3;
    private const SIGKILL = 9;

    /** @var resource|null */
    private $process;
    private readonly string $dir;
    private int $port = 0;

    /**
     * @param array<string, string> $env overrides of the container environment
     */
    public function __construct(private readonly array $env = [])
    {
        $dir = sys_get_temp_dir().'/flowcrm-fpm-'.bin2hex(random_bytes(6));
        if (!mkdir($dir, 0700)) {
            throw new \RuntimeException('cannot create '.$dir);
        }
        $this->dir = $dir;
    }

    public function start(): void
    {
        $this->port = self::freePort();
        file_put_contents($this->dir.'/fpm.conf', <<<CONF
            [global]
            error_log = {$this->dir}/fpm.log
            log_limit = 16384
            daemonize = no

            [probe]
            listen = 127.0.0.1:{$this->port}
            pm = static
            pm.max_children = 4
            clear_env = no
            catch_workers_output = yes
            decorate_workers_output = no
            CONF);

        $env = array_merge(getenv(), ['APP_ENV' => 'test', 'APP_DEBUG' => '0'], $this->env);
        $process = proc_open(
            ['php-fpm', '--nodaemonize', '--fpm-config', $this->dir.'/fpm.conf'],
            [0 => ['file', '/dev/null', 'r'], 1 => ['file', $this->dir.'/fpm.out', 'a'], 2 => ['file', $this->dir.'/fpm.out', 'a']],
            $pipes,
            '/app',
            $env,
        );
        if (!\is_resource($process)) {
            throw new \RuntimeException('php-fpm did not start');
        }
        $this->process = $process;

        for ($i = 0; $i < 100; ++$i) {
            $socket = @fsockopen('127.0.0.1', $this->port, $errno, $errstr, 0.1);
            if (false !== $socket) {
                fclose($socket);
                // The first request compiles the container; pay for it here.
                $this->request('GET', '/health/live');

                return;
            }
            usleep(100_000);
        }
        $this->stop();
        throw new \RuntimeException('php-fpm is not listening: '.$this->log());
    }

    /** Graceful stop (SIGQUIT): workers finish their requests. */
    public function stop(): void
    {
        if (null === $this->process) {
            return;
        }
        proc_terminate($this->process, self::SIGQUIT);
        for ($i = 0; $i < 100 && proc_get_status($this->process)['running']; ++$i) {
            usleep(50_000);
        }
        if (proc_get_status($this->process)['running']) {
            proc_terminate($this->process, self::SIGKILL);
        }
        proc_close($this->process);
        $this->process = null;
    }

    public function restart(): void
    {
        $this->stop();
        $this->start();
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
        $this->stop();
        foreach (glob($this->dir.'/*') ?: [] as $file) {
            unlink($file);
        }
        rmdir($this->dir);
    }

    /**
     * @param array<string, string> $cookies
     */
    public function request(string $method, string $uri, array $cookies = [], bool $https = false): FastCgiResponse
    {
        return $this->send([$this->begin($method, $uri, $cookies, $https)])[0];
    }

    /**
     * Sends the requests at the same time and waits for all of them.
     *
     * @param list<array{0: string, 1: string, 2?: array<string, string>}> $requests method, URI, cookies
     *
     * @return list<FastCgiResponse>
     */
    public function concurrently(array $requests): array
    {
        return $this->send(array_map(fn (array $r): array => $this->begin($r[0], $r[1], $r[2] ?? [], false), $requests));
    }

    /**
     * @param array<string, string> $cookies
     *
     * @return array{process: resource, stdout: resource}
     */
    private function begin(string $method, string $uri, array $cookies, bool $https): array
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
            'SCRIPT_FILENAME' => self::DOCUMENT_ROOT.'/index.php',
            'DOCUMENT_ROOT' => self::DOCUMENT_ROOT,
            'CONTENT_LENGTH' => '0',
            'HTTP_HOST' => 'localhost',
            'HTTP_ACCEPT' => 'application/json',
        ];
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

        // cgi-fcgi sends its whole environment as the FastCGI parameters.
        $process = proc_open(
            ['cgi-fcgi', '-bind', '-connect', '127.0.0.1:'.$this->port],
            [0 => ['file', '/dev/null', 'r'], 1 => ['pipe', 'w'], 2 => ['file', '/dev/null', 'w']],
            $pipes,
            null,
            $params,
        );
        if (!\is_resource($process)) {
            throw new \RuntimeException('cgi-fcgi did not start');
        }

        return ['process' => $process, 'stdout' => $pipes[1]];
    }

    /**
     * @param list<array{process: resource, stdout: resource}> $started
     *
     * @return list<FastCgiResponse>
     */
    private function send(array $started): array
    {
        $responses = [];
        foreach ($started as $request) {
            $output = (string) stream_get_contents($request['stdout']);
            fclose($request['stdout']);
            $exit = proc_close($request['process']);
            if (0 !== $exit) {
                throw new \RuntimeException(\sprintf('cgi-fcgi exited with %d: %s', $exit, $this->log()));
            }
            $responses[] = FastCgiResponse::parse($output);
        }

        return $responses;
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
