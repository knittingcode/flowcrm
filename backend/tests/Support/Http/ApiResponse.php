<?php

declare(strict_types=1);

namespace App\Tests\Support\Http;

use App\Tests\Support\Session\FastCgiResponse;
use PHPUnit\Framework\Assert;

final readonly class ApiResponse
{
    public function __construct(public FastCgiResponse $raw)
    {
    }

    public function status(): int
    {
        return $this->raw->status;
    }

    /** @return array<array-key, mixed> */
    public function json(): array
    {
        return $this->raw->json();
    }

    public function string(string $key): string
    {
        $value = $this->json()[$key] ?? null;
        Assert::assertIsString($value, "$key in ".$this->raw->body);

        return $value;
    }

    /** A nested member of the JSON body, such as value('meta', 'total'); null when it is missing. */
    public function value(string|int ...$path): mixed
    {
        $value = $this->json();
        foreach ($path as $key) {
            if (!\is_array($value) || !\array_key_exists($key, $value)) {
                return null;
            }
            $value = $value[$key];
        }

        return $value;
    }

    /** The problem type (/problems/<type>) of an error response. */
    public function problem(): string
    {
        Assert::assertSame(['application/problem+json'], $this->raw->header('Content-Type'), $this->raw->body);

        return $this->string('type');
    }

    public function header(string $name): ?string
    {
        $values = $this->raw->header($name);

        return [] === $values ? null : end($values);
    }

    /**
     * The body without the members that differ per request (request ID and
     * path), to compare two answers.
     *
     * @return array<array-key, mixed>
     */
    public function comparable(): array
    {
        $body = $this->json();
        unset($body['requestId'], $body['instance']);

        return $body;
    }
}
