<?php

declare(strict_types=1);

namespace App\Tests\Unit\Shared\Http;

use App\Shared\Http\RequestId;
use PHPUnit\Framework\TestCase;
use Symfony\Component\HttpFoundation\Request;
use Symfony\Component\Uid\Uuid;

final class RequestIdTest extends TestCase
{
    public function testAValidEdgeIdIsKept(): void
    {
        $request = Request::create('/api/v1/system/status');
        $request->headers->set('X-Request-Id', '0192F0C4-7D1E-7B8A-9F3C-2B4D6E8F0A1C');

        self::assertSame('0192f0c4-7d1e-7b8a-9f3c-2b4d6e8f0a1c', RequestId::of($request));
    }

    public function testAnInvalidIdIsReplaced(): void
    {
        $request = Request::create('/api/v1/system/status');
        $request->headers->set('X-Request-Id', "evil\r\nSet-Cookie: x=1");
        $id = RequestId::of($request);

        self::assertTrue(Uuid::isValid($id));
        self::assertSame($id, RequestId::of($request), 'the ID is stable for one request');
    }
}
