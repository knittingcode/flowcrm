<?php

declare(strict_types=1);

namespace App\Identity\Http\Security;

use App\Shared\Http\Problem\ProblemException;
use App\Shared\Http\Problem\ProblemResponse;
use Symfony\Component\HttpFoundation\Request;
use Symfony\Component\HttpFoundation\Response;
use Symfony\Component\Security\Core\Exception\AuthenticationException;
use Symfony\Component\Security\Http\EntryPoint\AuthenticationEntryPointInterface;
use Symfony\Component\Security\Http\Util\TargetPathTrait;

/**
 * 401 problem document for a request that needs a login: no redirect, no
 * details, and no session. Before calling this, the firewall stores the
 * requested URL in the session (the "target path" of a login redirect),
 * which would start and store a session for every anonymous request and
 * set a cookie. The SPA never redirects after a login on the server, so the
 * entry is removed again: an empty session is not stored, and a cookie the
 * request brought is expired.
 */
final readonly class ProblemEntryPoint implements AuthenticationEntryPointInterface
{
    use TargetPathTrait;

    private const FIREWALL = 'api';

    public function start(Request $request, ?AuthenticationException $authException = null): Response
    {
        if ($request->hasSession() && $request->getSession()->isStarted()) {
            $this->removeTargetPath($request->getSession(), self::FIREWALL);
        }

        return ProblemResponse::of($request, ProblemException::unauthenticated());
    }
}
