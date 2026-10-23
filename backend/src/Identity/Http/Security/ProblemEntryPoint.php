<?php

declare(strict_types=1);

namespace App\Identity\Http\Security;

use App\Shared\Http\Problem\ProblemException;
use App\Shared\Http\Problem\ProblemResponse;
use Symfony\Component\HttpFoundation\Request;
use Symfony\Component\HttpFoundation\Response;
use Symfony\Component\Security\Core\Exception\AuthenticationException;
use Symfony\Component\Security\Http\EntryPoint\AuthenticationEntryPointInterface;

/** 401 problem document for a request that needs a login: no redirect, no details. */
final readonly class ProblemEntryPoint implements AuthenticationEntryPointInterface
{
    public function start(Request $request, ?AuthenticationException $authException = null): Response
    {
        return ProblemResponse::of($request, ProblemException::unauthenticated());
    }
}
