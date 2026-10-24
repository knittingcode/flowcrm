<?php

declare(strict_types=1);

namespace App\Organizations\Http\Api;

use App\Organizations\Application\MemberView;

/** The Member representation of the API (openapi.yaml); the e-mail address only with membership.view_email. */
final class MemberJson
{
    /** @return array<string, string> */
    public static function of(MemberView $member, bool $withEmail): array
    {
        $view = [
            'membershipId' => $member->membershipId->toRfc4122(),
            'userId' => $member->userId->toRfc4122(),
            'displayName' => $member->displayName,
            'role' => $member->role,
        ];
        if ($withEmail) {
            $view['email'] = $member->email;
        }

        return $view;
    }
}
