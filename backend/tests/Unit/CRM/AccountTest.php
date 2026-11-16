<?php

declare(strict_types=1);

namespace App\Tests\Unit\CRM;

use App\CRM\Domain\Account;
use App\CRM\Domain\AccountArchived;
use App\CRM\Domain\AccountDetails;
use App\CRM\Domain\InvalidAccountDetails;
use PHPUnit\Framework\Attributes\DataProvider;
use PHPUnit\Framework\TestCase;
use Symfony\Component\Uid\Uuid;

final class AccountTest extends TestCase
{
    public function testDetailsAreTrimmedAndEmptyOptionalValuesAreNull(): void
    {
        $details = AccountDetails::of("  Acme Sp. z o.o. \n", '', '   ', null);

        self::assertSame('Acme Sp. z o.o.', $details->name);
        self::assertNull($details->website);
        self::assertNull($details->email);
        self::assertNull($details->phone);
    }

    public function testValidDetailsAreKept(): void
    {
        $details = AccountDetails::of('Zażółć Gęślą', 'https://example.test/kontakt?x=1', 'biuro@example.test', '+48 (22) 123-45-67');

        self::assertSame(['Zażółć Gęślą', 'https://example.test/kontakt?x=1', 'biuro@example.test', '+48 (22) 123-45-67'], [$details->name, $details->website, $details->email, $details->phone]);
        self::assertSame(str_repeat('ż', 200), AccountDetails::of(str_repeat('ż', 200))->name, 'the limit counts characters');
    }

    /** @return iterable<string, array{array{string, ?string, ?string, ?string}, array<string, string>}> */
    public static function invalid(): iterable
    {
        yield 'blank name' => [['   ', null, null, null], ['name' => 'BLANK']];
        yield 'empty name' => [['', null, null, null], ['name' => 'BLANK']];
        yield 'long name' => [[str_repeat('a', 201), null, null, null], ['name' => 'TOO_LONG']];
        yield 'NUL in the name' => [["Ac\0me", null, null, null], ['name' => 'INVALID_CHARACTERS']];
        yield 'line break in the name' => [["Ac\nme", null, null, null], ['name' => 'INVALID_CHARACTERS']];
        yield 'invalid UTF-8' => [["Ac\xffme", null, null, null], ['name' => 'INVALID_CHARACTERS']];
        yield 'website without a scheme' => [['Acme', 'example.test', null, null], ['website' => 'INVALID_URL']];
        yield 'website with another scheme' => [['Acme', 'javascript:alert(1)', null, null], ['website' => 'INVALID_URL']];
        yield 'website with ftp' => [['Acme', 'ftp://example.test', null, null], ['website' => 'INVALID_URL']];
        yield 'website with credentials' => [['Acme', 'https://user:secret@example.test', null, null], ['website' => 'INVALID_URL']];
        yield 'website with a space' => [['Acme', 'https://exa mple.test', null, null], ['website' => 'INVALID_URL']];
        yield 'long website' => [['Acme', 'https://example.test/'.str_repeat('a', 2030), null, null], ['website' => 'TOO_LONG']];
        yield 'e-mail without a domain' => [['Acme', null, 'biuro@', null], ['email' => 'INVALID_EMAIL']];
        yield 'long e-mail' => [['Acme', null, str_repeat('a', 243).'@example.test', null], ['email' => 'TOO_LONG']];
        yield 'phone with letters' => [['Acme', null, null, 'call me'], ['phone' => 'INVALID_PHONE']];
        yield 'short phone' => [['Acme', null, null, '12'], ['phone' => 'INVALID_PHONE']];
        yield 'long phone' => [['Acme', null, null, '+'.str_repeat('1', 50)], ['phone' => 'TOO_LONG']];
        yield 'every field at once' => [['', 'x', 'y', 'z'], ['name' => 'BLANK', 'website' => 'INVALID_URL', 'email' => 'INVALID_EMAIL', 'phone' => 'INVALID_PHONE']];
    }

    /**
     * @param array{string, ?string, ?string, ?string} $values
     * @param array<string, string>                    $violations
     */
    #[DataProvider('invalid')]
    public function testInvalidDetailsNameEachFieldWithACode(array $values, array $violations): void
    {
        try {
            AccountDetails::of(...$values);
            self::fail('accepted');
        } catch (InvalidAccountDetails $e) {
            self::assertSame($violations, $e->violations);
        }
    }

    public function testAChangeReportsTheChangedFieldsAndTheTime(): void
    {
        $created = new \DateTimeImmutable('2026-11-16T10:00:00+00:00');
        $account = new Account(Uuid::v7(), Uuid::v7(), AccountDetails::of('Acme', null, 'a@example.test'), $created);
        self::assertEquals($created, $account->updatedAt());

        $later = $created->modify('+1 hour');
        self::assertSame([], $account->change(AccountDetails::of(' Acme ', '', 'a@example.test'), $later), 'the same details');
        self::assertEquals($created, $account->updatedAt(), 'nothing changed');

        self::assertSame(['name', 'email', 'phone'], $account->change(AccountDetails::of('Acme SA', null, null, '+48 22 123 45 67'), $later));
        self::assertSame(['Acme SA', null, null, '+48 22 123 45 67'], [$account->name(), $account->website(), $account->email(), $account->phone()]);
        self::assertEquals($later, $account->updatedAt());
        self::assertEquals($created, $account->createdAt());
    }

    public function testAnArchivedAccountIsArchivedOnceAndCannotBeChanged(): void
    {
        $created = new \DateTimeImmutable('2026-11-16T10:00:00+00:00');
        $account = new Account(Uuid::v7(), Uuid::v7(), AccountDetails::of('Acme'), $created);
        self::assertNull($account->archivedAt());

        self::assertTrue($account->archive($created->modify('+1 day')));
        self::assertFalse($account->archive($created->modify('+2 days')), 'already archived');
        self::assertEquals($created->modify('+1 day'), $account->archivedAt());
        self::assertEquals($created->modify('+1 day'), $account->updatedAt());

        $this->expectException(AccountArchived::class);
        $account->change(AccountDetails::of('Other'), $created->modify('+3 days'));
    }
}
