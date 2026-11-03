<?php

declare(strict_types=1);

namespace App\Identity\Http\Security;

use Monolog\Attribute\WithMonologChannel;
use Psr\Log\LoggerInterface;
use Symfony\Component\EventDispatcher\Attribute\AsEventListener;
use Symfony\Component\Security\Http\Event\TokenDeauthenticatedEvent;

/**
 * The firewall dropped the session's token because the user changed (gone,
 * disabled, new password) or the absolute lifetime is over: the whole
 * session ends (row deleted, new ID), not only the token, so its CSRF token
 * and data cannot be reused.
 */
#[WithMonologChannel('security')]
final readonly class SessionEndListener
{
    public function __construct(private LoggerInterface $logger)
    {
    }

    #[AsEventListener]
    public function __invoke(TokenDeauthenticatedEvent $event): void
    {
        $request = $event->getRequest();
        if ($request->hasSession()) {
            $request->getSession()->invalidate();
        }
        $this->logger->info('session ended by the server', ['event' => 'session_ended', 'user_id' => $event->getOriginalToken()->getUserIdentifier()]);
    }
}
