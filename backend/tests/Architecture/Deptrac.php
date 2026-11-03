<?php

declare(strict_types=1);

namespace App\Tests\Architecture;

use Symfony\Component\Yaml\Yaml;

/**
 * Runs Deptrac with one of the project's configurations against a source
 * tree and returns its violations as "Layer on Layer: Source -> Target".
 */
final class Deptrac
{
    public const MODULES = 'deptrac.modules.yaml';
    public const LAYERS = 'deptrac.layers.yaml';

    public static function backendDir(): string
    {
        return \dirname(__DIR__, 2);
    }

    /**
     * @param array<string, string> $files PHP sources by path relative to src/
     *
     * @return list<string>
     */
    public static function violationsIn(string $config, array $files): array
    {
        $dir = sys_get_temp_dir().'/flowcrm-deptrac-'.bin2hex(random_bytes(6));
        try {
            foreach ($files as $path => $code) {
                $file = $dir.'/src/'.$path;
                if (!is_dir(\dirname($file)) && !mkdir(\dirname($file), 0o700, true)) {
                    throw new \RuntimeException('Cannot create '.\dirname($file));
                }
                file_put_contents($file, $code);
            }

            $parsed = Yaml::parseFile(self::backendDir().'/'.$config);
            if (!\is_array($parsed) || !\is_array($parsed['deptrac'] ?? null)) {
                throw new \UnexpectedValueException($config.' has no deptrac section');
            }
            $parsed['deptrac']['paths'] = [$dir.'/src'];
            file_put_contents($dir.'/deptrac.yaml', Yaml::dump($parsed, 8));

            return self::run($dir.'/deptrac.yaml', $dir.'/report.json');
        } finally {
            self::remove($dir);
        }
    }

    /**
     * @return list<string>
     */
    public static function run(string $configFile, string $report): array
    {
        $command = [
            \PHP_BINARY,
            self::backendDir().'/vendor/bin/deptrac',
            'analyse',
            '--config-file='.$configFile,
            '--no-cache',
            '--no-progress',
            '--formatter=json',
            '--output='.$report,
        ];
        $process = proc_open($command, [1 => ['pipe', 'w'], 2 => ['pipe', 'w']], $pipes);
        if (!\is_resource($process)) {
            throw new \RuntimeException('Cannot start Deptrac');
        }
        $output = stream_get_contents($pipes[1]).stream_get_contents($pipes[2]);
        fclose($pipes[1]);
        fclose($pipes[2]);
        $exit = proc_close($process);

        $json = is_file($report) ? json_decode((string) file_get_contents($report), true) : null;
        if (!\is_array($json) || !\is_array($json['Report'] ?? null) || 0 !== ($json['Report']['Errors'] ?? null)) {
            throw new \RuntimeException(\sprintf("Deptrac failed (exit %d):\n%s", $exit, $output));
        }

        $violations = [];
        $files = \is_array($json['files'] ?? null) ? $json['files'] : [];
        foreach ($files as $file) {
            $messages = \is_array($file) && \is_array($file['messages'] ?? null) ? $file['messages'] : [];
            foreach ($messages as $message) {
                if (!\is_array($message) || 'error' !== ($message['type'] ?? null) || !\is_string($message['message'] ?? null)) {
                    continue;
                }
                if (1 === preg_match('/^(\S+) must not depend on (\S+) \((\S+) on (\S+)\)$/', $message['message'], $m)) {
                    $violations[] = $m[3].' on '.$m[4].': '.$m[1].' -> '.$m[2];
                }
            }
        }
        sort($violations);

        return $violations;
    }

    private static function remove(string $path): void
    {
        if (is_dir($path) && !is_link($path)) {
            foreach (scandir($path) ?: [] as $entry) {
                if ('.' !== $entry && '..' !== $entry) {
                    self::remove($path.'/'.$entry);
                }
            }
            rmdir($path);
        } elseif (file_exists($path) || is_link($path)) {
            unlink($path);
        }
    }
}
