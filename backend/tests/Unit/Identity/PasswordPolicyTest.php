<?php

declare(strict_types=1);

namespace App\Tests\Unit\Identity;

use App\Identity\Domain\PasswordPolicy;
use PHPUnit\Framework\Attributes\DataProvider;
use PHPUnit\Framework\TestCase;

final class PasswordPolicyTest extends TestCase
{
    /** @return iterable<string, array{string, list<string>}> */
    public static function passwords(): iterable
    {
        yield '11 characters' => [str_repeat('a', 11), ['PASSWORD_TOO_SHORT']];
        yield '12 characters' => [str_repeat('a', 12), []];
        yield '12 multibyte characters (24 bytes)' => [str_repeat('ż', 12), []];
        yield '11 multibyte characters' => [str_repeat('ż', 11), ['PASSWORD_TOO_SHORT']];
        yield '128 characters' => [str_repeat('a', 128), []];
        yield '129 characters' => [str_repeat('a', 129), ['PASSWORD_TOO_LONG']];
        yield '128 multibyte characters (256 bytes)' => [str_repeat('ż', 128), []];
        yield 'no composition rules: spaces only' => [str_repeat(' ', 12), []];
        yield 'invalid UTF-8' => ["\xff".str_repeat('a', 12), ['PASSWORD_INVALID']];
    }

    /** @param list<string> $violations */
    #[DataProvider('passwords')]
    public function testLengthIsCountedInCharacters(string $password, array $violations): void
    {
        self::assertSame($violations, PasswordPolicy::violations($password));
    }
}
