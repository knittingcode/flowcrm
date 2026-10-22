<?php

declare(strict_types=1);

namespace App\Tests\Support\Session;

/**
 * A response as PHP-FPM returned it over FastCGI: CGI headers (with a
 * Status header unless the status is 200) and the body.
 */
final readonly class FastCgiResponse
{
    /**
     * @param list<array{0: string, 1: string}> $headers name (lower case) and value, in order
     */
    private function __construct(
        public int $status,
        public array $headers,
        public string $body,
    ) {
    }

    public static function parse(string $output): self
    {
        $split = strpos($output, "\r\n\r\n");
        if (false === $split) {
            throw new \UnexpectedValueException('no header block in: '.$output);
        }
        $headers = [];
        $status = 200;
        foreach (explode("\r\n", substr($output, 0, $split)) as $line) {
            [$name, $value] = array_map('trim', explode(':', $line, 2)) + [1 => ''];
            $name = strtolower($name);
            if ('status' === $name) {
                $status = (int) $value;
            } else {
                $headers[] = [$name, $value];
            }
        }

        return new self($status, $headers, substr($output, $split + 4));
    }

    /** @return list<string> */
    public function header(string $name): array
    {
        $values = [];
        foreach ($this->headers as [$header, $value]) {
            if ($header === strtolower($name)) {
                $values[] = $value;
            }
        }

        return $values;
    }

    /**
     * The Set-Cookie header values for one cookie.
     *
     * @return list<string>
     */
    public function setCookies(string $cookie): array
    {
        return array_values(array_filter(
            $this->header('Set-Cookie'),
            static fn (string $value): bool => str_starts_with($value, $cookie.'='),
        ));
    }

    /** The value the response sets for the cookie, or null if it sets none. */
    public function cookieValue(string $cookie): ?string
    {
        $set = $this->setCookies($cookie);
        if ([] === $set) {
            return null;
        }
        $pair = explode(';', end($set), 2)[0];

        return urldecode(substr($pair, \strlen($cookie) + 1));
    }

    /** @return array<array-key, mixed> */
    public function json(): array
    {
        $data = json_decode($this->body, true, flags: \JSON_THROW_ON_ERROR);
        if (!\is_array($data)) {
            throw new \UnexpectedValueException('not a JSON object: '.$this->body);
        }

        return $data;
    }
}
