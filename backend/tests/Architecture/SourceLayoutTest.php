<?php

declare(strict_types=1);

namespace App\Tests\Architecture;

use PHPUnit\Framework\TestCase;
use Symfony\Component\Yaml\Yaml;

/**
 * The Deptrac rules only constrain classes their layers collect. Every class
 * under src/ must therefore live in src/<Module>/<Layer>/, with a module
 * from deptrac.modules.yaml and a layer from deptrac.layers.yaml; only the
 * Kernel sits at the root.
 */
final class SourceLayoutTest extends TestCase
{
    public function testTheApplicationHasNoArchitectureViolations(): void
    {
        $dir = sys_get_temp_dir().'/flowcrm-deptrac-'.bin2hex(random_bytes(6));
        mkdir($dir, 0o700);
        try {
            foreach ([Deptrac::MODULES, Deptrac::LAYERS] as $config) {
                self::assertSame([], Deptrac::run(Deptrac::backendDir().'/'.$config, $dir.'/report.json'), $config);
            }
        } finally {
            @unlink($dir.'/report.json');
            rmdir($dir);
        }
    }

    public function testEverySourceFileIsInAModuleAndLayer(): void
    {
        self::assertSame([], self::misplaced(Deptrac::backendDir().'/src'));
    }

    public function testMisplacedFilesAreReported(): void
    {
        $dir = sys_get_temp_dir().'/flowcrm-layout-'.bin2hex(random_bytes(6));
        $files = ['Kernel.php', 'Sales/Domain/Opportunity.php', 'Billing/Domain/Invoice.php', 'Sales/Service/Helper.php', 'Sales/Loose.php', 'Helper.php'];
        try {
            foreach ($files as $file) {
                if (!is_dir(\dirname($dir.'/'.$file))) {
                    mkdir(\dirname($dir.'/'.$file), 0o700, true);
                }
                touch($dir.'/'.$file);
            }

            self::assertSame(['Billing/Domain/Invoice.php', 'Helper.php', 'Sales/Loose.php', 'Sales/Service/Helper.php'], self::misplaced($dir));
        } finally {
            foreach ($files as $file) {
                unlink($dir.'/'.$file);
            }
            foreach (['Sales/Domain', 'Sales/Service', 'Sales', 'Billing/Domain', 'Billing', ''] as $sub) {
                rmdir($dir.'/'.$sub);
            }
        }
    }

    /**
     * @return list<string> PHP files under $src that are outside src/<Module>/<Layer>/
     */
    private static function misplaced(string $src): array
    {
        $modules = array_values(array_filter(self::layerNames(Deptrac::MODULES), static fn (string $name): bool => !str_ends_with($name, 'Api')));
        $layers = self::layerNames(Deptrac::LAYERS);

        $misplaced = [];
        $files = new \RecursiveIteratorIterator(new \RecursiveDirectoryIterator($src, \FilesystemIterator::SKIP_DOTS));
        foreach ($files as $file) {
            if (!$file instanceof \SplFileInfo || 'php' !== $file->getExtension()) {
                continue;
            }
            $path = substr($file->getPathname(), \strlen($src) + 1);
            $parts = explode('/', $path);
            $placed = 'Kernel.php' === $path
                || (\count($parts) >= 3 && \in_array($parts[0], $modules, true) && \in_array($parts[1], $layers, true));
            if (!$placed) {
                $misplaced[] = $path;
            }
        }
        sort($misplaced);

        return $misplaced;
    }

    /**
     * @return list<string> the layers of a configuration whose names are App namespaces
     */
    private static function layerNames(string $config): array
    {
        $parsed = Yaml::parseFile(Deptrac::backendDir().'/'.$config);
        $layers = \is_array($parsed) && \is_array($parsed['deptrac'] ?? null) && \is_array($parsed['deptrac']['layers'] ?? null) ? $parsed['deptrac']['layers'] : [];

        $names = [];
        foreach ($layers as $layer) {
            if (\is_array($layer) && \is_string($layer['name'] ?? null) && \is_array($layer['collectors'] ?? null)
                && str_contains((string) json_encode($layer['collectors']), '^App\\\\')) {
                $names[] = $layer['name'];
            }
        }

        return $names;
    }
}
