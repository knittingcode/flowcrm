<?php

declare(strict_types=1);

namespace App\Tests\Support\Http;

/** A request ApiClient::dispatch() started; ApiClient::collect() waits for its response. */
final readonly class PendingRequest
{
    /**
     * @param array{process: resource, stdout: resource, label: string} $handle
     */
    public function __construct(
        public ApiClient $client,
        public string $method,
        public string $uri,
        public array $handle,
    ) {
    }
}
