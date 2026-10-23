<?php

declare(strict_types=1);

namespace App\Shared\Http\Query;

use App\Shared\Http\Problem\ProblemException;
use Symfony\Component\HttpFoundation\Request;

/**
 * page and pageSize of a list request (FCRM-003 section I): page >= 1
 * (default 1), pageSize 1 to 100 (default 25). Any other query parameter is
 * a 422, so a client cannot slip in filters (or an organization ID) that
 * the endpoint does not define.
 */
final readonly class Pagination
{
    public const MAX_PAGE_SIZE = 100;

    private function __construct(public int $page, public int $pageSize)
    {
    }

    public static function of(Request $request): self
    {
        $errors = [];
        foreach ($request->query->keys() as $name) {
            if (!\in_array($name, ['page', 'pageSize'], true)) {
                $errors[] = ['parameter' => (string) $name, 'code' => 'UNKNOWN_PARAMETER'];
            }
        }
        $page = self::integer($request, 'page', 1, 1, \PHP_INT_MAX, $errors);
        $pageSize = self::integer($request, 'pageSize', 25, 1, self::MAX_PAGE_SIZE, $errors);
        if ([] !== $errors) {
            throw ProblemException::validation($errors);
        }

        return new self($page, $pageSize);
    }

    /**
     * @param list<array{parameter: string, code: string}> $errors
     */
    private static function integer(Request $request, string $name, int $default, int $min, int $max, array &$errors): int
    {
        if (!$request->query->has($name)) {
            return $default;
        }
        $raw = $request->query->all()[$name];
        if (!\is_string($raw) || 1 !== preg_match('/^[0-9]{1,9}$/', $raw)) {
            $errors[] = ['parameter' => $name, 'code' => 'INVALID_TYPE'];

            return $default;
        }
        $value = (int) $raw;
        if ($value < $min || $value > $max) {
            $errors[] = ['parameter' => $name, 'code' => 'OUT_OF_RANGE'];

            return $default;
        }

        return $value;
    }
}
