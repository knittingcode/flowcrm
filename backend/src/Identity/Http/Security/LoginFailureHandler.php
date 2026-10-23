<?php

declare(strict_types=1);

namespace App\Identity\Http\Security;

use App\Shared\Http\Problem\ProblemException;
use App\Shared\Http\Problem\ProblemResponse;
use App\Shared\Http\Security\LogPseudonym;
use Monolog\Attribute\WithMonologChannel;
use Psr\Log\LoggerInterface;
use Symfony\Component\HttpFoundation\Request;
use Symfony\Component\HttpFoundation\Response;
use Symfony\Component\Security\Core\Exception\AuthenticationException;
use Symfony\Component\Security\Core\Exception\DisabledException;
use Symfony\Component\Security\Core\Exception\TooManyLoginAttemptsAuthenticationException;
use Symfony\Component\Security\Http\Authentication\AuthenticationFailureHandlerInterface;
use Symfony\Component\Security\Http\SecurityRequestAttributes;

/**
 * One answer for every failed login (unknown e-mail, wrong password,
 * disabled account): 401 invalid-credentials, and 429 with Retry-After once
 * a limit is reached, for known and unknown accounts alike. The reason goes
 * to the security log only, with pseudonyms instead of the e-mail and IP
 * address. Failed logins are not written to the immutable audit log, so
 * anonymous traffic cannot fill it.
 */
#[WithMonologChannel('security')]
final readonly class LoginFailureHandler implements AuthenticationFailureHandlerInterface
{
    public function __construct(
        private LoggerInterface $logger,
        private LogPseudonym $pseudonym,
    ) {
    }

    public function onAuthenticationFailure(Request $request, AuthenticationException $exception): Response
    {
        $email = $request->attributes->get(SecurityRequestAttributes::LAST_USERNAME);
        $context = [
            'event' => 'login_failed',
            'account_ref' => $this->pseudonym->of(\is_string($email) ? mb_strtolower($email) : null),
            'client_ref' => $this->pseudonym->of($request->getClientIp()),
        ];

        if ($exception instanceof TooManyLoginAttemptsAuthenticationException) {
            $minutes = $exception->getMessageData()['%minutes%'] ?? 1;
            $this->logger->warning('login throttled', $context + ['reason' => 'throttled']);

            return ProblemResponse::of($request, ProblemException::tooManyRequests(60 * (is_numeric($minutes) ? (int) $minutes : 1)));
        }

        $this->logger->warning('login failed', $context + ['reason' => $exception instanceof DisabledException ? 'disabled' : 'invalid_credentials']);

        return ProblemResponse::of($request, ProblemException::invalidCredentials());
    }
}
