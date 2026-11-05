<?php

declare(strict_types=1);

namespace App\Tests\Unit\Shared\Http\Security;

use PHPUnit\Framework\TestCase;
use Symfony\Component\HttpFoundation\Request;
use Symfony\Component\HttpFoundation\RequestMatcher\MethodRequestMatcher;

/**
 * Pins the fix of CVE-2026-118514 (symfony/http-foundation 7.4.23): a matcher
 * restricted to GET also applies to HEAD, which the router serves with the GET
 * handler. security.access_control rules and firewalls compile to this matcher.
 */
final class MethodMatcherHeadTest extends TestCase
{
    public function testAMatcherForGetAppliesToHead(): void
    {
        self::assertTrue((new MethodRequestMatcher('GET'))->matches(Request::create('/', 'HEAD')));
    }

    public function testAMatcherForPostDoesNotApplyToHead(): void
    {
        self::assertFalse((new MethodRequestMatcher('POST'))->matches(Request::create('/', 'HEAD')));
    }
}
