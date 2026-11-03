<?php

declare(strict_types=1);

namespace App\Shared\Http\Problem;

use Symfony\Component\HttpKernel\Exception\HttpException;

/**
 * An HTTP error with an RFC 9457 problem type of its own (rendered by
 * ProblemDetailsListener as /problems/<type>) and optional extension members,
 * such as the "errors" list of a validation problem. The exception message is
 * never sent to the client.
 */
final class ProblemException extends HttpException
{
    /**
     * @param array<string, mixed>  $extensions members added to the problem document
     * @param array<string, string> $headers
     */
    public function __construct(
        int $status,
        private readonly string $type,
        private readonly array $extensions = [],
        array $headers = [],
    ) {
        parent::__construct($status, $type, null, $headers);
    }

    /** No valid session: anonymous, expired or ended (FCRM-003 section I). */
    public static function unauthenticated(): self
    {
        return new self(401, 'unauthenticated', headers: ['WWW-Authenticate' => 'Session realm="flowcrm"']);
    }

    /** A failed login, whatever the reason. */
    public static function invalidCredentials(): self
    {
        return new self(401, 'invalid-credentials', headers: ['WWW-Authenticate' => 'Session realm="flowcrm"']);
    }

    /** The Origin check or the CSRF token of an unsafe request failed. */
    public static function csrfInvalid(): self
    {
        return new self(403, 'csrf-invalid');
    }

    public static function forbidden(): self
    {
        return new self(403, 'forbidden');
    }

    /** Unknown, foreign and invisible resources look the same (FCRM-003 C-05). */
    public static function notFound(): self
    {
        return new self(404, 'not-found');
    }

    public static function unsupportedMediaType(): self
    {
        return new self(415, 'unsupported-media-type');
    }

    /**
     * @param non-empty-list<array{pointer?: string, parameter?: string, code: string}> $errors
     */
    public static function validation(array $errors): self
    {
        return new self(422, 'validation-error', ['errors' => $errors]);
    }

    public static function tooManyRequests(int $retryAfterSeconds): self
    {
        return new self(429, 'too-many-requests', headers: ['Retry-After' => (string) max(1, $retryAfterSeconds)]);
    }

    public function type(): string
    {
        return $this->type;
    }

    /** @return array<string, mixed> */
    public function extensions(): array
    {
        return $this->extensions;
    }
}
