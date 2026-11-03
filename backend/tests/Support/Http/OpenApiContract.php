<?php

declare(strict_types=1);

namespace App\Tests\Support\Http;

use App\Tests\Support\Session\FastCgiResponse;
use cebe\openapi\spec\OpenApi;
use League\OpenAPIValidation\PSR7\Exception\ValidationFailed;
use League\OpenAPIValidation\PSR7\PathFinder;
use League\OpenAPIValidation\PSR7\ResponseValidator;
use League\OpenAPIValidation\PSR7\ValidatorBuilder;
use Nyholm\Psr7\Response;
use PHPUnit\Framework\Assert;

/**
 * Checks real responses against the committed specification
 * (backend/openapi.yaml): every /api/v1 response that the API tests receive
 * must be declared, with its status, media type, headers and body schema.
 * A path the specification does not know may only be a 404 or 405.
 */
final class OpenApiContract
{
    public const SPEC = __DIR__.'/../../../openapi.yaml';

    private static ?ResponseValidator $validator = null;

    public static function spec(): OpenApi
    {
        return self::validator()->getSchema();
    }

    public static function assertResponse(string $method, string $uri, FastCgiResponse $response): void
    {
        $path = (string) parse_url($uri, \PHP_URL_PATH);
        if (!str_starts_with($path, '/api/v1/')) {
            return;
        }
        $operations = new PathFinder(self::spec(), $path, strtolower($method))->search();
        if ([] === $operations) {
            Assert::assertContains($response->status, [404, 405], \sprintf('%s %s is not in the specification but answered %d', $method, $path, $response->status));

            return;
        }

        $headers = [];
        foreach ($response->headers as [$name, $value]) {
            $headers[$name][] = $value;
        }
        try {
            self::validator()->validate($operations[0], new Response($response->status, $headers, $response->body));
        } catch (ValidationFailed $e) {
            $reasons = [];
            for ($error = $e; null !== $error; $error = $error->getPrevious()) {
                $reasons[] = $error->getMessage();
            }
            Assert::fail(\sprintf("%s %s answered %d, which the specification does not allow:\n- %s\nbody: %s", $method, $path, $response->status, implode("\n- ", $reasons), $response->body));
        }
    }

    private static function validator(): ResponseValidator
    {
        return self::$validator ??= new ValidatorBuilder()->fromYamlFile(self::SPEC)->getResponseValidator();
    }
}
