<?php

declare(strict_types=1);

namespace App\Organizations\Application;

use App\Identity\Api\UserDirectory;
use Symfony\Component\Uid\Uuid;

/** The member directory of one organization (FCRM-002 section H: name and role). */
final readonly class MemberDirectory
{
    public function __construct(
        private OrganizationReadModel $organizations,
        private UserDirectory $users,
    ) {
    }

    /** @return array{list<MemberView>, int} */
    public function page(Uuid $organizationId, int $page, int $pageSize): array
    {
        [$rows, $total] = $this->organizations->members($organizationId, ($page - 1) * $pageSize, $pageSize);

        return [$this->views($rows), $total];
    }

    public function member(Uuid $organizationId, Uuid $membershipId): ?MemberView
    {
        $row = $this->organizations->member($organizationId, $membershipId);

        return null === $row ? null : ($this->views([$row])[0] ?? null);
    }

    /**
     * @param list<MemberRow> $rows
     *
     * @return list<MemberView>
     */
    private function views(array $rows): array
    {
        $profiles = $this->users->profiles(array_map(static fn (MemberRow $row): Uuid => $row->userId, $rows));
        $views = [];
        foreach ($rows as $row) {
            $profile = $profiles[$row->userId->toRfc4122()] ?? null;
            if (null !== $profile) {
                $views[] = new MemberView($row->membershipId, $row->userId, $profile->displayName, $profile->email, $row->role);
            }
        }

        return $views;
    }
}
