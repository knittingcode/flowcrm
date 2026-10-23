<?php

declare(strict_types=1);

/*
 * Runs the security negative controls (controls.php, tests/app/backend.sh
 * BE-18): the backend is copied once to a temporary directory; for each
 * control one file of the copy is mutated, the named tests run against the
 * copy (including the PHP-FPM tests, which serve the copy) and must report
 * failures; then the file is restored. The checkout is never changed.
 *
 * Usage: php tests/Mutation/run-controls.php [label substring]
 */

$source = dirname(__DIR__, 2);
$only = $argv[1] ?? '';
/** @var list<array{string, string, string, string, string}> $controls */
$controls = require __DIR__.'/controls.php';

$copy = sys_get_temp_dir().'/flowcrm-controls-'.bin2hex(random_bytes(4));
passthru('cp -R '.escapeshellarg($source).' '.escapeshellarg($copy), $copied);
if (0 !== $copied) {
    fwrite(\STDERR, "cannot copy the backend\n");
    exit(2);
}

$failed = 0;
$ran = 0;
foreach ($controls as [$label, $file, $search, $replace, $tests]) {
    if ('' !== $only && !str_contains($label, $only)) {
        continue;
    }
    ++$ran;
    $path = $copy.'/'.$file;
    $original = (string) file_get_contents($path);
    if (1 !== substr_count($original, $search)) {
        printf("FAIL  %s: the mutation does not apply (%d matches in %s)\n", $label, substr_count($original, $search), $file);
        ++$failed;
        continue;
    }
    file_put_contents($path, str_replace($search, $replace, $original));
    exec('php -l '.escapeshellarg($path).' 2>&1', $lint, $lintExit);
    if (str_ends_with($file, '.php') && 0 !== $lintExit) {
        printf("FAIL  %s: the mutated file does not compile\n", $label);
        ++$failed;
        file_put_contents($path, $original);
        continue;
    }
    exec('rm -rf '.escapeshellarg($copy.'/var/cache'));

    $output = [];
    exec('cd '.escapeshellarg($copy).' && php vendor/bin/phpunit --colors=never --filter '.escapeshellarg($tests).' 2>&1', $output, $exit);
    file_put_contents($path, $original);

    $summary = (string) end($output);
    $detected = 0 !== $exit && (str_contains(implode("\n", $output), 'FAILURES!') || str_contains(implode("\n", $output), 'ERRORS!')) && !str_contains(implode("\n", $output), 'No tests executed');
    printf("%s  %s -> %s\n", $detected ? 'PASS' : 'FAIL', $label, $detected ? 'detected: '.$summary : 'NOT detected by '.$tests.' ('.$summary.')');
    if (!$detected) {
        ++$failed;
    }
}
exec('rm -rf '.escapeshellarg($copy));

printf("%d of %d negative controls detected\n", $ran - $failed, $ran);
exit(0 === $failed && $ran > 0 ? 0 : 1);
