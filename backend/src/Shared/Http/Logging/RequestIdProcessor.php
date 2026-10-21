<?php

declare(strict_types=1);

namespace App\Shared\Http\Logging;

use App\Shared\Http\RequestId;
use Monolog\Attribute\AsMonologProcessor;
use Monolog\LogRecord;
use Symfony\Component\HttpFoundation\RequestStack;

/**
 * Adds the request ID of the current HTTP request to every log record, so
 * application logs, the edge access log and problem documents correlate.
 */
#[AsMonologProcessor]
final readonly class RequestIdProcessor
{
    public function __construct(private RequestStack $requests)
    {
    }

    public function __invoke(LogRecord $record): LogRecord
    {
        $request = $this->requests->getMainRequest();
        if (null !== $request) {
            $record->extra['request_id'] = RequestId::of($request);
        }

        return $record;
    }
}
