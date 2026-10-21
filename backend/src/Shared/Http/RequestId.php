<?php

declare(strict_types=1);

namespace App\Shared\Http;

use Symfony\Component\EventDispatcher\Attribute\AsEventListener;
use Symfony\Component\HttpFoundation\Request;
use Symfony\Component\HttpKernel\Event\RequestEvent;
use Symfony\Component\HttpKernel\Event\ResponseEvent;
use Symfony\Component\HttpKernel\KernelEvents;
use Symfony\Component\Uid\Uuid;

/**
 * Uses the X-Request-Id set by the edge when it is a UUID, otherwise
 * generates one, and returns it on every response.
 */
final class RequestId
{
    public const HEADER = 'X-Request-Id';
    private const ATTRIBUTE = '_request_id';

    public static function of(Request $request): string
    {
        $id = $request->attributes->get(self::ATTRIBUTE);
        if (\is_string($id)) {
            return $id;
        }

        $header = $request->headers->get(self::HEADER);
        $id = null !== $header && Uuid::isValid($header) ? strtolower($header) : Uuid::v7()->toRfc4122();
        $request->attributes->set(self::ATTRIBUTE, $id);

        return $id;
    }

    #[AsEventListener(event: KernelEvents::REQUEST, priority: 512)]
    public function onRequest(RequestEvent $event): void
    {
        self::of($event->getRequest());
    }

    #[AsEventListener(event: KernelEvents::RESPONSE)]
    public function onResponse(ResponseEvent $event): void
    {
        $event->getResponse()->headers->set(self::HEADER, self::of($event->getRequest()));
    }
}
