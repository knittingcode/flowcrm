<?php

declare(strict_types=1);

namespace App\Shared\Infrastructure\Logging;

use Monolog\Formatter\FormatterInterface;
use Monolog\LogRecord;

/**
 * One JSON object per line (FCRM-003 section Q): ts, level, channel,
 * message, request_id and the remaining context. Context and extra data are
 * redacted before the message placeholders are filled in, so a placeholder
 * cannot reintroduce a redacted value.
 */
final class JsonLineFormatter implements FormatterInterface
{
    public function format(LogRecord $record): string
    {
        $context = LogRedactor::redact($record->context);
        $extra = LogRedactor::redact($record->extra);

        $message = $record->message;
        $exception = $record->context['exception'] ?? null;
        if ($exception instanceof \Throwable) {
            $message = LogRedactor::withoutRawMessages($message, $exception);
        }

        $line = [
            'ts' => $record->datetime->setTimezone(new \DateTimeZone('UTC'))->format('Y-m-d\TH:i:s.v\Z'),
            'level' => strtolower($record->level->getName()),
            'channel' => $record->channel,
            'message' => self::interpolate(LogRedactor::scrub($message), $context),
            'request_id' => $extra['request_id'] ?? null,
        ];
        unset($extra['request_id']);
        if ([] !== $context) {
            $line['context'] = $context;
        }
        if ([] !== $extra) {
            $line['extra'] = $extra;
        }

        return json_encode($line, \JSON_UNESCAPED_SLASHES | \JSON_UNESCAPED_UNICODE | \JSON_INVALID_UTF8_SUBSTITUTE | \JSON_PARTIAL_OUTPUT_ON_ERROR)."\n";
    }

    /**
     * @param list<LogRecord> $records
     */
    public function formatBatch(array $records): string
    {
        return implode('', array_map($this->format(...), $records));
    }

    /**
     * @param array<array-key, mixed> $context
     */
    private static function interpolate(string $message, array $context): string
    {
        if (!str_contains($message, '{')) {
            return $message;
        }

        return (string) preg_replace_callback('/\{([A-Za-z0-9_.]+)\}/', static function (array $m) use ($context): string {
            if (!\array_key_exists($m[1], $context)) {
                return $m[0];
            }
            $value = $context[$m[1]];

            return match (true) {
                null === $value => 'null',
                \is_bool($value) => $value ? 'true' : 'false',
                \is_scalar($value) => (string) $value,
                \is_array($value) => (string) json_encode($value, \JSON_UNESCAPED_SLASHES | \JSON_PARTIAL_OUTPUT_ON_ERROR),
                default => '['.get_debug_type($value).']',
            };
        }, $message);
    }
}
