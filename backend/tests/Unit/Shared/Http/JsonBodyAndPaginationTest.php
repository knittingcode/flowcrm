<?php

declare(strict_types=1);

namespace App\Tests\Unit\Shared\Http;

use App\Shared\Http\Json\JsonBody;
use App\Shared\Http\Problem\ProblemException;
use App\Shared\Http\Query\Pagination;
use PHPUnit\Framework\TestCase;
use Symfony\Component\HttpFoundation\Request;
use Symfony\Component\HttpKernel\Exception\BadRequestHttpException;

final class JsonBodyAndPaginationTest extends TestCase
{
    public function testAnObjectWithTheExpectedStringMembers(): void
    {
        self::assertSame(['a' => 'x', 'b' => 'y'], JsonBody::strings($this->body('{"b":"y","a":"x"}'), ['a', 'b']));
    }

    public function testMalformedBodiesAreBadRequests(): void
    {
        foreach (['', '{', '[]', '[1]', '"a"', 'null', '1'] as $content) {
            try {
                JsonBody::strings($this->body($content), ['a']);
                self::fail($content);
            } catch (BadRequestHttpException) {
                $this->addToAssertionCount(1);
            }
        }
    }

    public function testUnknownMissingAndMistypedMembersAreNamed(): void
    {
        try {
            JsonBody::strings($this->body('{"a":1,"x/y":"z"}'), ['a', 'b']);
            self::fail('accepted');
        } catch (ProblemException $e) {
            self::assertSame(422, $e->getStatusCode());
            self::assertSame(['errors' => [
                ['pointer' => '/x~1y', 'code' => 'UNKNOWN_FIELD'],
                ['pointer' => '/a', 'code' => 'INVALID_TYPE'],
                ['pointer' => '/b', 'code' => 'REQUIRED'],
            ]], $e->extensions());
        }
    }

    public function testPaginationDefaultsAndLimits(): void
    {
        $default = Pagination::of(Request::create('/x'));
        self::assertSame([1, 25], [$default->page, $default->pageSize]);
        $max = Pagination::of(Request::create('/x?page=3&pageSize=100'));
        self::assertSame([3, 100], [$max->page, $max->pageSize]);

        foreach (['pageSize=101', 'pageSize=0', 'page=0', 'page=-1', 'page=1.5', 'page=1e3', 'pageSize[]=1', 'organizationId=x', 'page=9999999999'] as $query) {
            try {
                Pagination::of(Request::create('/x?'.$query));
                self::fail($query);
            } catch (ProblemException $e) {
                self::assertSame(422, $e->getStatusCode(), $query);
            }
        }
    }

    private function body(string $content): Request
    {
        return Request::create('/api/x', 'POST', server: ['CONTENT_TYPE' => 'application/json'], content: $content);
    }
}
