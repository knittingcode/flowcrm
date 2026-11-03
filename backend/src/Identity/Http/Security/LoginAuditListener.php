<?php

declare(strict_types=1);

namespace App\Identity\Http\Security;

use App\Audit\Api\Actor;
use App\Audit\Api\AuditRecord;
use App\Audit\Api\AuditTrail;
use App\Shared\Http\RequestId;
use App\Shared\Http\Security\RequestOriginGuard;
use Monolog\Attribute\WithMonologChannel;
use Psr\Log\LoggerInterface;
use Symfony\Component\EventDispatcher\Attribute\AsEventListener;
use Symfony\Component\Security\Core\Authentication\Token\Storage\TokenStorageInterface;
use Symfony\Component\Security\Csrf\CsrfTokenManagerInterface;
use Symfony\Component\Security\Http\Event\LoginSuccessEvent;
use Symfony\Component\Uid\Uuid;

/**
 * After a successful login: a new CSRF token (rotation after
 * authentication) and the audit event auth.login_succeeded, without an IP
 * address. If the audit event cannot be written, the login fails: the token
 * is dropped and the session invalidated before the error propagates.
 */
#[WithMonologChannel('security')]
final readonly class LoginAuditListener
{
    /** Request attribute: this request was authenticated by json_login. */
    public const AUTHENTICATED = '_flowcrm_login';

    public function __construct(
        private AuditTrail $audit,
        private CsrfTokenManagerInterface $csrf,
        private TokenStorageInterface $tokens,
        private LoggerInterface $logger,
    ) {
    }

    #[AsEventListener]
    public function __invoke(LoginSuccessEvent $event): void
    {
        $request = $event->getRequest();
        $userId = Uuid::fromString($event->getAuthenticatedToken()->getUserIdentifier());
        try {
            $this->audit->record(new AuditRecord('auth.login_succeeded', 'user', $userId, Actor::user($userId), requestId: Uuid::fromString(RequestId::of($request))));
        } catch (\Throwable $e) {
            $this->tokens->setToken(null);
            if ($request->hasSession()) {
                $request->getSession()->invalidate();
            }

            throw $e;
        }
        $this->csrf->refreshToken(RequestOriginGuard::TOKEN_ID);
        $request->attributes->set(self::AUTHENTICATED, true);
        $this->logger->info('login succeeded', ['event' => 'login_succeeded', 'user_id' => $userId->toRfc4122()]);
    }
}
