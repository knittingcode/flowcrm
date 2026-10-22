<?php

declare(strict_types=1);

namespace App\Shared\Http\Session;

use Symfony\Component\EventDispatcher\Attribute\AsEventListener;
use Symfony\Component\HttpFoundation\Session\Storage\NativeSessionStorage;
use Symfony\Component\HttpKernel\Event\ExceptionEvent;
use Symfony\Component\HttpKernel\Event\ResponseEvent;
use Symfony\Component\HttpKernel\KernelEvents;

/**
 * When starting the session fails with an exception (for example the
 * session lock times out in PdoSessionHandler while PHP validates the ID),
 * PHP's session module may already have queued a Set-Cookie header with a
 * new, never stored ID. Symfony removes PHP's session cookie only for
 * sessions that started, so the browser would replace its valid session
 * cookie and lose the session. This drops that header, and only for
 * requests whose session start failed.
 */
final class FailedSessionStartListener
{
    private const ATTRIBUTE = '_session_start_failed';

    #[AsEventListener(event: KernelEvents::EXCEPTION, priority: 256)]
    public function onException(ExceptionEvent $event): void
    {
        for ($e = $event->getThrowable(); null !== $e; $e = $e->getPrevious()) {
            foreach ($e->getTrace() as $frame) {
                if (NativeSessionStorage::class === ($frame['class'] ?? null) && 'start' === $frame['function']) {
                    $event->getRequest()->attributes->set(self::ATTRIBUTE, true);

                    return;
                }
            }
        }
    }

    #[AsEventListener(event: KernelEvents::RESPONSE, priority: -1000)]
    public function onResponse(ResponseEvent $event): void
    {
        $request = $event->getRequest();
        if (!$event->isMainRequest() || true !== $request->attributes->get(self::ATTRIBUTE) || !$request->hasSession(true)) {
            return;
        }

        $prefix = 'Set-Cookie: '.urlencode($request->getSession()->getName()).'=';
        $kept = [];
        $dropped = false;
        foreach (headers_list() as $header) {
            if (0 === stripos($header, 'Set-Cookie:')) {
                if (0 === stripos($header, $prefix)) {
                    $dropped = true;
                } else {
                    $kept[] = $header;
                }
            }
        }
        if ($dropped) {
            header_remove('Set-Cookie');
            foreach ($kept as $header) {
                header($header, false);
            }
        }
    }
}
