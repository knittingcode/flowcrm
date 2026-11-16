<?php

declare(strict_types=1);

namespace App\Shared\Http\Json;

use App\Shared\Http\Problem\ProblemException;
use Symfony\Component\HttpFoundation\Request;
use Symfony\Component\HttpKernel\Exception\BadRequestHttpException;

/**
 * Strict reading of a JSON request body with string members only (optional
 * ones may be null): a body
 * that is not a JSON object is a 400, unknown members (mass-assignment
 * guard, FCRM-003 section I), missing members and members of another type
 * are a 422 that names the member. The Content-Type is enforced before
 * (RequestOriginGuard).
 */
final class JsonBody
{
    /**
     * @param non-empty-list<string> $fields the allowed and required members
     *
     * @return array<string, string>
     */
    public static function strings(Request $request, array $fields): array
    {
        try {
            $decoded = json_decode($request->getContent(), false, 8, \JSON_THROW_ON_ERROR);
        } catch (\JsonException) {
            throw new BadRequestHttpException('The body is not valid JSON.');
        }
        if (!$decoded instanceof \stdClass) {
            throw new BadRequestHttpException('The body is not a JSON object.');
        }
        $body = get_object_vars($decoded);

        $errors = [];
        foreach (array_keys($body) as $name) {
            if (!\in_array($name, $fields, true)) {
                $errors[] = ['pointer' => '/'.self::escape((string) $name), 'code' => 'UNKNOWN_FIELD'];
            }
        }
        $values = [];
        foreach ($fields as $name) {
            if (!\array_key_exists($name, $body)) {
                $errors[] = ['pointer' => '/'.self::escape($name), 'code' => 'REQUIRED'];
            } elseif (!\is_string($body[$name])) {
                $errors[] = ['pointer' => '/'.self::escape($name), 'code' => 'INVALID_TYPE'];
            } else {
                $values[$name] = $body[$name];
            }
        }
        if ([] !== $errors) {
            throw ProblemException::validation($errors);
        }

        return $values;
    }

    /**
     * Like strings(), with optional members: an optional member may be
     * missing or null (both are null in the result) or a string.
     *
     * @param non-empty-list<string> $required
     * @param list<string>           $optional
     *
     * @return array<string, string|null> every required and optional member
     */
    public static function fields(Request $request, array $required, array $optional): array
    {
        try {
            $decoded = json_decode($request->getContent(), false, 8, \JSON_THROW_ON_ERROR);
        } catch (\JsonException) {
            throw new BadRequestHttpException('The body is not valid JSON.');
        }
        if (!$decoded instanceof \stdClass) {
            throw new BadRequestHttpException('The body is not a JSON object.');
        }
        $body = get_object_vars($decoded);

        $errors = [];
        foreach (array_keys($body) as $name) {
            if (!\in_array($name, $required, true) && !\in_array($name, $optional, true)) {
                $errors[] = ['pointer' => '/'.self::escape((string) $name), 'code' => 'UNKNOWN_FIELD'];
            }
        }
        $values = [];
        foreach ($required as $name) {
            if (!\array_key_exists($name, $body)) {
                $errors[] = ['pointer' => '/'.self::escape($name), 'code' => 'REQUIRED'];
            } elseif (!\is_string($body[$name])) {
                $errors[] = ['pointer' => '/'.self::escape($name), 'code' => 'INVALID_TYPE'];
            } else {
                $values[$name] = $body[$name];
            }
        }
        foreach ($optional as $name) {
            $value = $body[$name] ?? null;
            if (null !== $value && !\is_string($value)) {
                $errors[] = ['pointer' => '/'.self::escape($name), 'code' => 'INVALID_TYPE'];
            } else {
                $values[$name] = $value;
            }
        }
        if ([] !== $errors) {
            throw ProblemException::validation($errors);
        }

        return $values;
    }

    /** JSON Pointer escaping (RFC 6901). */
    private static function escape(string $name): string
    {
        return str_replace(['~', '/'], ['~0', '~1'], $name);
    }
}
