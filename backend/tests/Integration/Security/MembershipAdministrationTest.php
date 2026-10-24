<?php

declare(strict_types=1);

namespace App\Tests\Integration\Security;

use App\Tests\Support\Database\FailingAudit;
use App\Tests\Support\Database\TestDatabase;
use App\Tests\Support\Http\ApiClient;
use App\Tests\Support\Http\ApiResponse;
use App\Tests\Support\Http\FpmApiTestCase;
use App\Tests\Support\Http\PendingRequest;
use App\Tests\Support\Security\TestUser;
use App\Tests\Support\Session\SeparateConnection;
use Symfony\Component\Uid\Uuid;

/**
 * Membership administration over the real PHP-FPM and PostgreSQL
 * (FCRM-FND-010C, ADR-020; FCRM-002 REQ-013 to REQ-015, BR-02, BR-03,
 * AC-09, TI-04). Organization A has an ADMIN, a MANAGER, a REP and a
 * removed member; B has its own ADMIN and a REP.
 */
final class MembershipAdministrationTest extends FpmApiTestCase
{
    use FailingAudit;

    private Uuid $a;
    private Uuid $b;
    private TestUser $adminA;
    private TestUser $managerA;
    private TestUser $repA;
    private TestUser $removedA;
    private TestUser $adminB;
    private Uuid $adminAMembership;
    private Uuid $managerAMembership;
    private Uuid $repAMembership;
    private Uuid $removedAMembership;
    private Uuid $repBMembership;

    protected function setUp(): void
    {
        parent::setUp();
        $this->a = $this->fixtures->organization('alpha');
        $this->b = $this->fixtures->organization('beta');
        $this->adminA = $this->fixtures->user('admin-a');
        $this->managerA = $this->fixtures->user('manager-a');
        $this->repA = $this->fixtures->user('rep-a');
        $this->removedA = $this->fixtures->user('removed-a');
        $this->adminB = $this->fixtures->user('admin-b');
        $this->adminAMembership = $this->fixtures->member($this->a, $this->adminA, 'ADMIN');
        $this->managerAMembership = $this->fixtures->member($this->a, $this->managerA, 'MANAGER');
        $this->repAMembership = $this->fixtures->member($this->a, $this->repA, 'REP');
        $this->removedAMembership = $this->fixtures->member($this->a, $this->removedA, 'REP');
        $this->fixtures->removeMembership($this->removedAMembership);
        $this->fixtures->member($this->b, $this->adminB, 'ADMIN');
        $this->repBMembership = $this->fixtures->member($this->b, $this->fixtures->user('rep-b'), 'REP');
    }

    /** AC-09: an ADMIN adds an existing user; the change and its audit event carry the request. */
    public function testAnAdminAddsAnExistingUser(): void
    {
        $user = $this->fixtures->user('joining');
        $client = $this->logIn($this->adminA);

        $response = $client->post($this->members(), ['email' => strtoupper($user->email), 'role' => 'MANAGER']);

        self::assertSame(201, $response->status(), $response->raw->body);
        $id = $response->string('membershipId');
        self::assertSame($this->members().'/'.$id, $response->header('Location'));
        self::assertSame($user->id->toRfc4122(), $response->value('userId'));
        self::assertSame($user->displayName, $response->value('displayName'));
        self::assertSame('MANAGER', $response->value('role'));
        self::assertSame($user->email, $response->value('email'), 'ADMIN has membership.view_email');
        self::assertSame(['role' => 'MANAGER', 'status' => 'ACTIVE', 'organization_id' => $this->a->toRfc4122(), 'user_id' => $user->id->toRfc4122()], $this->membership(Uuid::fromString($id)));

        $events = $this->events(Uuid::fromString($id));
        self::assertCount(1, $events);
        self::assertSame('membership.added', $events[0]['action']);
        self::assertSame('user', $events[0]['actor_type']);
        self::assertSame($this->adminA->id->toRfc4122(), $events[0]['actor_user_id']);
        self::assertSame('ADMIN', $events[0]['actor_role']);
        self::assertSame($this->a->toRfc4122(), $events[0]['organization_id']);
        self::assertSame(['role' => 'MANAGER'], $events[0]['changes']);
        self::assertSame($response->header('X-Request-Id'), $events[0]['request_id']);
        self::assertStringNotContainsString(strtolower($user->email), strtolower(json_encode($events, \JSON_THROW_ON_ERROR)), 'no e-mail address in the audit log');

        $joined = $this->logIn($user)->get('/api/v1/organizations/'.$this->a->toRfc4122());
        self::assertSame(200, $joined->status());
        self::assertSame('MANAGER', $joined->value('membership', 'role'));
    }

    /** BR-02: one membership per user and organization; a removed one is not reactivated. */
    public function testAnExistingOrRemovedMembershipCannotBeAddedAgain(): void
    {
        $client = $this->logIn($this->adminA);
        $before = $this->snapshot();

        foreach ([$this->managerA, $this->removedA] as $user) {
            $response = $client->post($this->members(), ['email' => $user->email, 'role' => 'REP']);
            self::assertSame(409, $response->status(), $user->email);
            self::assertSame('/problems/conflict', $response->problem());
            self::assertSame([['code' => 'MEMBERSHIP_EXISTS']], $response->value('errors'));
        }

        self::assertSame($before, $this->snapshot());
    }

    public function testInvalidRequestsAreValidationErrors(): void
    {
        $client = $this->logIn($this->adminA);
        $cases = [
            [['email' => 'nobody-'.bin2hex(random_bytes(3)).'@example.test', 'role' => 'REP'], [['pointer' => '/email', 'code' => 'UNKNOWN_USER']]],
            [['email' => $this->fixtures->user('valid')->email, 'role' => 'OWNER'], [['pointer' => '/role', 'code' => 'INVALID_ROLE']]],
            [['email' => $this->fixtures->user('lower')->email, 'role' => 'admin'], [['pointer' => '/role', 'code' => 'INVALID_ROLE']]],
            [['email' => $this->fixtures->user('extra')->email, 'role' => 'REP', 'organizationId' => $this->b->toRfc4122()], [['pointer' => '/organizationId', 'code' => 'UNKNOWN_FIELD']]],
            [['email' => $this->fixtures->user('status')->email, 'role' => 'REP', 'status' => 'ACTIVE'], [['pointer' => '/status', 'code' => 'UNKNOWN_FIELD']]],
            [['email' => $this->fixtures->user('missing')->email], [['pointer' => '/role', 'code' => 'REQUIRED']]],
            [['email' => $this->fixtures->user('typed')->email, 'role' => 1], [['pointer' => '/role', 'code' => 'INVALID_TYPE']]],
        ];
        $before = $this->snapshot();
        foreach ($cases as [$body, $errors]) {
            $response = $client->post($this->members(), $body);
            self::assertSame(422, $response->status(), json_encode($body, \JSON_THROW_ON_ERROR));
            self::assertSame('/problems/validation-error', $response->problem());
            self::assertSame($errors, $response->value('errors'));
        }

        foreach ([[['role' => 'OWNER'], [['pointer' => '/role', 'code' => 'INVALID_ROLE']]], [['role' => 'ADMIN', 'userId' => $this->adminA->id->toRfc4122()], [['pointer' => '/userId', 'code' => 'UNKNOWN_FIELD']]], [['role' => null], [['pointer' => '/role', 'code' => 'INVALID_TYPE']]]] as [$body, $errors]) {
            $response = $client->patch($this->member($this->repAMembership), $body);
            self::assertSame(422, $response->status(), json_encode($body, \JSON_THROW_ON_ERROR));
            self::assertSame($errors, $response->value('errors'));
        }

        self::assertSame($before, $this->snapshot());
    }

    /** The status order: an unknown target is a 404 before the body is validated. */
    public function testAnUnknownTargetIsNotFoundBeforeTheBodyIsValidated(): void
    {
        $client = $this->logIn($this->adminA);

        self::assertSame(404, $client->patch($this->member(Uuid::v7()), ['role' => 'OWNER'])->status());
        self::assertSame(404, $client->patch($this->member($this->removedAMembership), ['unknown' => 'x'])->status());
    }

    /** Only ADMIN may add, change or remove; MANAGER and REP get 403 and nothing changes. */
    public function testManagersAndRepsMayNotAdministerMemberships(): void
    {
        $outsider = $this->fixtures->user('outsider');
        $before = $this->snapshot();

        $readOnly = [
            'MANAGER' => [$this->managerA, ['organization.view', 'membership.list', 'membership.view_email']],
            'REP' => [$this->repA, ['organization.view', 'membership.list']],
        ];
        foreach ($readOnly as [$user, $permissions]) {
            $client = $this->logIn($user);
            $responses = [
                $client->post($this->members(), ['email' => $outsider->email, 'role' => 'REP']),
                $client->patch($this->member($this->repAMembership), ['role' => 'ADMIN']),
                $client->patch($this->member($this->managerAMembership), ['role' => 'ADMIN']),
                $client->delete($this->member($this->adminAMembership)),
                $client->delete($this->member($this->repAMembership)),
            ];
            foreach ($responses as $i => $response) {
                self::assertSame(403, $response->status(), $user->email.' #'.$i);
                self::assertSame('/problems/forbidden', $response->problem());
            }
            self::assertSame($permissions, $client->get('/api/v1/organizations/'.$this->a->toRfc4122())->value('membership', 'permissions'), 'unchanged by FND-010C');
        }

        self::assertSame($before, $this->snapshot());
    }

    /** C-05: another organization is the same 404 as an unknown one, also for the new routes. */
    public function testAForeignOrganizationIsNotFound(): void
    {
        $client = $this->logIn($this->adminB);
        $before = $this->snapshot();
        $unknown = Uuid::v7();

        foreach ([$this->a, $unknown] as $organization) {
            $base = '/api/v1/organizations/'.$organization->toRfc4122().'/members';
            foreach ([
                $client->post($base, ['email' => $this->adminB->email, 'role' => 'ADMIN']),
                $client->patch($base.'/'.$this->repAMembership->toRfc4122(), ['role' => 'ADMIN']),
                $client->delete($base.'/'.$this->repAMembership->toRfc4122()),
            ] as $i => $response) {
                self::assertSame(404, $response->status(), $organization->toRfc4122().' #'.$i);
                self::assertSame('/problems/not-found', $response->problem());
            }
        }

        self::assertSame($before, $this->snapshot());
    }

    /** IDOR: a membership of B under A's path is a 404, and B's membership stays as it was. */
    public function testAMembershipOfAnotherOrganizationIsNotFound(): void
    {
        $client = $this->logIn($this->adminA);
        $before = $this->snapshot();

        $patch = $client->patch($this->member($this->repBMembership), ['role' => 'ADMIN']);
        $unknown = $client->patch($this->member(Uuid::v7()), ['role' => 'ADMIN']);
        $delete = $client->delete($this->member($this->repBMembership));

        self::assertSame(404, $patch->status());
        self::assertSame($unknown->comparable(), $patch->comparable());
        self::assertSame(404, $delete->status());
        self::assertSame($before, $this->snapshot());
        self::assertSame([], $this->events($this->repBMembership));
    }

    /** BR-03, AC-09: the only ADMIN can neither demote nor remove themselves. */
    public function testTheLastAdminCannotBeDemotedOrRemoved(): void
    {
        $client = $this->logIn($this->adminA);
        $before = $this->snapshot();

        foreach ([
            $client->patch($this->member($this->adminAMembership), ['role' => 'MANAGER']),
            $client->patch($this->member($this->adminAMembership), ['role' => 'REP']),
            $client->delete($this->member($this->adminAMembership)),
        ] as $i => $response) {
            self::assertSame(409, $response->status(), '#'.$i);
            self::assertSame('/problems/conflict', $response->problem());
            self::assertSame([['code' => 'LAST_ADMIN']], $response->value('errors'));
        }

        self::assertSame($before, $this->snapshot());
        self::assertSame([], $this->events($this->adminAMembership));
        self::assertSame(200, $client->patch($this->member($this->repAMembership), ['role' => 'MANAGER'])->status(), 'still ADMIN');
    }

    /** With two ADMINs one may be demoted, also by themselves, and the change applies on the next request (TI-04). */
    public function testWithTwoAdminsOneMayBeDemoted(): void
    {
        $second = $this->fixtures->user('second-admin');
        $secondMembership = $this->fixtures->member($this->a, $second, 'ADMIN');
        $client = $this->logIn($this->adminA);
        $secondClient = $this->logIn($second);

        $demoted = $client->patch($this->member($secondMembership), ['role' => 'MANAGER']);
        self::assertSame(200, $demoted->status(), $demoted->raw->body);
        self::assertSame('MANAGER', $demoted->value('role'));
        self::assertSame($secondMembership->toRfc4122(), $demoted->value('membershipId'));
        $events = $this->events($secondMembership);
        self::assertSame(['membership.role_changed'], array_column($events, 'action'));
        self::assertEquals(['roleFrom' => 'ADMIN', 'roleTo' => 'MANAGER'], $events[0]['changes'], 'jsonb does not keep the key order');
        self::assertSame($demoted->header('X-Request-Id'), $events[0]['request_id']);
        self::assertSame('ADMIN', $events[0]['actor_role']);
        self::assertSame('user', $events[0]['actor_type']);
        self::assertSame($this->adminA->id->toRfc4122(), $events[0]['actor_user_id']);
        self::assertSame($this->a->toRfc4122(), $events[0]['organization_id']);
        self::assertStringNotContainsString('@', json_encode($events, \JSON_THROW_ON_ERROR), 'no e-mail address in the audit log');

        $next = $secondClient->get('/api/v1/organizations/'.$this->a->toRfc4122());
        self::assertSame('MANAGER', $next->value('membership', 'role'));
        self::assertSame(['organization.view', 'membership.list', 'membership.view_email'], $next->value('membership', 'permissions'));
        self::assertSame(403, $secondClient->delete($this->member($this->repAMembership))->status(), 'no longer ADMIN');

        $this->fixtures->changeRole($secondMembership, 'ADMIN');
        $self = $client->patch($this->member($this->adminAMembership), ['role' => 'REP']);
        self::assertSame(200, $self->status(), 'one of two ADMINs demotes themselves');
        self::assertSame(['membership.role_changed'], array_column($this->events($this->adminAMembership), 'action'));
        self::assertSame(['organization.view', 'membership.list'], $client->get('/api/v1/organizations/'.$this->a->toRfc4122())->value('membership', 'permissions'));
        self::assertSame(['ADMIN'], $this->activeAdmins(), 'the other ADMIN remains');
    }

    /**
     * Current behaviour, pinned for ADR-020's open decision on disabled
     * ADMINs: the last-admin rule counts active memberships whatever the
     * account state, so the only enabled ADMIN may step down while a
     * disabled ADMIN remains, leaving only the disabled one.
     */
    public function testADisabledAdminCountsForTheLastAdminRule(): void
    {
        $disabled = $this->fixtures->user('disabled-admin');
        $disabledMembership = $this->fixtures->member($this->a, $disabled, 'ADMIN');
        $this->fixtures->connection()->executeStatement('UPDATE users SET disabled_at = now() WHERE id = ?', [$disabled->id->toRfc4122()]);
        $client = $this->logIn($this->adminA);

        $demoted = $client->patch($this->member($this->adminAMembership), ['role' => 'MANAGER']);

        self::assertSame(200, $demoted->status(), $demoted->raw->body);
        self::assertSame('MANAGER', $demoted->value('role'));
        self::assertSame(['membership.role_changed'], array_column($this->events($this->adminAMembership), 'action'));
        self::assertSame(['role' => 'ADMIN', 'status' => 'ACTIVE', 'organization_id' => $this->a->toRfc4122(), 'user_id' => $disabled->id->toRfc4122()], $this->membership($disabledMembership));
        self::assertSame(['ADMIN'], $this->activeAdmins(), 'only the disabled ADMIN is left');
    }

    /** With two ADMINs one may be removed, also by themselves; the removed user's next request is a 404 (TI-04). */
    public function testWithTwoAdminsOneMayBeRemoved(): void
    {
        $second = $this->fixtures->user('second-admin');
        $secondMembership = $this->fixtures->member($this->a, $second, 'ADMIN');
        $client = $this->logIn($this->adminA);

        $removed = $client->delete($this->member($this->adminAMembership));

        self::assertSame(204, $removed->status(), $removed->raw->body);
        self::assertSame('', $removed->raw->body);
        self::assertSame('REMOVED', $this->membership($this->adminAMembership)['status'] ?? null);
        $events = $this->events($this->adminAMembership);
        self::assertSame(['membership.removed'], array_column($events, 'action'));
        self::assertSame(['role' => 'ADMIN'], $events[0]['changes']);
        self::assertSame(404, $client->get('/api/v1/organizations/'.$this->a->toRfc4122())->status(), 'the removed ADMIN no longer sees the organization');
        self::assertSame(404, $client->delete($this->member($this->repAMembership))->status());

        $last = $this->logIn($second);
        self::assertSame(409, $last->delete($this->member($secondMembership))->status(), 'now the last ADMIN');
    }

    /** C-11: a removal is soft; a repeated DELETE and a PATCH of a removed membership are 404s. */
    public function testARemovedMembershipIsNotFoundAgain(): void
    {
        $client = $this->logIn($this->adminA);
        $rep = $this->logIn($this->repA);
        self::assertSame(200, $rep->get('/api/v1/organizations/'.$this->a->toRfc4122())->status());

        self::assertSame(204, $client->delete($this->member($this->repAMembership))->status());
        $row = $this->fixtures->connection()->fetchAssociative('SELECT status, removed_at FROM memberships WHERE id = ?', [$this->repAMembership->toRfc4122()]);
        self::assertIsArray($row);
        self::assertSame('REMOVED', $row['status']);
        self::assertNotNull($row['removed_at'], 'the row stays, marked as removed');

        foreach ([$client->delete($this->member($this->repAMembership)), $client->patch($this->member($this->repAMembership), ['role' => 'REP']), $client->delete($this->member($this->removedAMembership))] as $i => $response) {
            self::assertSame(404, $response->status(), '#'.$i);
            self::assertSame('/problems/not-found', $response->problem());
        }
        self::assertSame(['membership.removed'], array_column($this->events($this->repAMembership), 'action'));
        self::assertSame(['role' => 'REP'], $this->events($this->repAMembership)[0]['changes']);
        self::assertSame(404, $rep->get('/api/v1/organizations/'.$this->a->toRfc4122())->status(), 'the removed user\'s next request');
    }

    public function testTheSameRoleAgainChangesNothing(): void
    {
        $response = $this->logIn($this->adminA)->patch($this->member($this->repAMembership), ['role' => 'REP']);

        self::assertSame(200, $response->status());
        self::assertSame('REP', $response->value('role'));
        self::assertSame([], $this->events($this->repAMembership), 'no audit event without a change');
    }

    /** BR-31: a change and its audit event are one transaction; without the event nothing changes. */
    public function testAChangeWhoseAuditEventCannotBeWrittenChangesNothing(): void
    {
        $client = $this->logIn($this->adminA);
        $user = $this->fixtures->user('never-added');
        $before = $this->snapshot();

        $patch = $this->whileAuditFailsFor($this->repAMembership, fn () => $client->patch($this->member($this->repAMembership), ['role' => 'ADMIN']));
        $delete = $this->whileAuditFailsFor($this->managerAMembership, fn () => $client->delete($this->member($this->managerAMembership)));
        $post = $this->whileAuditFails(\sprintf("NEW.action = 'membership.added' AND NEW.organization_id = '%s'", $this->a->toRfc4122()), fn () => $client->post($this->members(), ['email' => $user->email, 'role' => 'REP']));

        foreach ([$patch, $delete, $post] as $i => $response) {
            self::assertSame(500, $response->status(), '#'.$i);
            self::assertSame('/problems/internal-error', $response->problem());
            self::assertSame($response->header('X-Request-Id'), $response->value('requestId'));
        }
        self::assertSame($before, $this->snapshot());
        self::assertSame([], $this->events($this->repAMembership));
        self::assertSame([], $this->events($this->managerAMembership));
        self::assertSame(200, $client->patch($this->member($this->repAMembership), ['role' => 'MANAGER'])->status(), 'the lock was released');
    }

    /**
     * The response is built from data read inside the change's transaction:
     * when that read fails, the change and its audit event are rolled back,
     * so the 500 means that nothing was changed and the request can be
     * repeated.
     */
    public function testAChangeWhoseResponseCannotBeBuiltChangesNothing(): void
    {
        $client = $this->logIn($this->adminA);
        $user = $this->fixtures->user('response-fails');
        $before = $this->snapshot();

        $post = $this->whileTheProfileCannotBeRead($user->id, fn (): ApiResponse => $client->post($this->members(), ['email' => $user->email, 'role' => 'REP']));
        $patch = $this->whileTheProfileCannotBeRead($this->repA->id, fn (): ApiResponse => $client->patch($this->member($this->repAMembership), ['role' => 'MANAGER']));

        foreach (['POST' => $post, 'PATCH' => $patch] as $label => $response) {
            self::assertSame(500, $response->status(), $label.' '.$response->raw->body);
            self::assertSame('/problems/internal-error', $response->problem(), $label);
            self::assertSame($response->header('X-Request-Id'), $response->value('requestId'), $label);
        }
        self::assertSame($before, $this->snapshot(), 'neither change nor its audit event was saved');
        self::assertSame(201, $client->post($this->members(), ['email' => $user->email, 'role' => 'REP'])->status(), 'the add can be repeated');
        self::assertSame(200, $client->patch($this->member($this->repAMembership), ['role' => 'MANAGER'])->status(), 'the lock was released');
        self::assertSame(['membership.role_changed'], array_column($this->events($this->repAMembership), 'action'));
    }

    /** ADR-019: the new unsafe routes need the session's CSRF token and the same origin. */
    public function testTheNewRoutesNeedTheCsrfTokenAndTheSameOrigin(): void
    {
        $client = $this->logIn($this->adminA);
        $user = $this->fixtures->user('forged');
        $before = $this->snapshot();

        foreach ([['HTTP_X_CSRF_TOKEN' => null], ['HTTP_X_CSRF_TOKEN' => 'forged'], ['HTTP_ORIGIN' => 'https://evil.example'], ['HTTP_SEC_FETCH_SITE' => 'cross-site']] as $headers) {
            $label = json_encode($headers, \JSON_THROW_ON_ERROR);
            foreach ([
                $client->post($this->members(), ['email' => $user->email, 'role' => 'ADMIN'], $headers),
                $client->patch($this->member($this->repAMembership), ['role' => 'ADMIN'], $headers),
                $client->delete($this->member($this->repAMembership), $headers),
            ] as $i => $response) {
                self::assertSame(403, $response->status(), $label.' #'.$i);
                self::assertSame('/problems/csrf-invalid', $response->problem());
            }
        }
        self::assertSame(415, $client->post($this->members(), null, ['CONTENT_TYPE' => 'text/plain'], '{"email":"x","role":"ADMIN"}')->status());

        self::assertSame($before, $this->snapshot());
    }

    /**
     * Two ADMINs demote each other at the same time: the organization lock
     * runs the requests one after the other, and the second sees that its
     * actor is no longer ADMIN. Exactly one ADMIN remains.
     */
    public function testConcurrentDemotionsLeaveExactlyOneAdmin(): void
    {
        $second = $this->fixtures->user('second-admin');
        $secondMembership = $this->fixtures->member($this->a, $second, 'ADMIN');
        $first = $this->logIn($this->adminA);
        $other = $this->logIn($second);

        $holder = SeparateConnection::open();
        $holder->beginTransaction();
        $holder->prepare('SELECT id FROM organizations WHERE id = ? FOR NO KEY UPDATE')->execute([$this->a->toRfc4122()]);
        try {
            $pending = [
                $first->dispatch('PATCH', $this->member($secondMembership), ['role' => 'MANAGER']),
                $other->dispatch('PATCH', $this->member($this->adminAMembership), ['role' => 'MANAGER']),
            ];
            $waiting = $this->requestsWaitingForTheOrganizationLock($holder, 2);
            $holder->rollBack();
            $responses = ApiClient::collect(...$pending);
        } finally {
            if ($holder->inTransaction()) {
                $holder->rollBack();
            }
        }

        self::assertSame(2, $waiting, 'both requests waited for the organization lock');
        $statuses = array_map(static fn (ApiResponse $r): int => $r->status(), $responses);
        sort($statuses);
        self::assertSame([200, 403], $statuses, 'the second request is refused: its actor was demoted');
        self::assertSame(['ADMIN'], $this->activeAdmins());
        self::assertCount(1, [...$this->events($secondMembership), ...$this->events($this->adminAMembership)], 'one change, one audit event');
    }

    /** An ADMIN demoted while their request waits for the lock is refused: the authorization before the lock is not trusted. */
    public function testTheActorIsCheckedAgainUnderTheLock(): void
    {
        $second = $this->fixtures->user('second-admin');
        $this->fixtures->member($this->a, $second, 'ADMIN');
        $client = $this->logIn($this->adminA);
        $before = $this->membership($this->repAMembership);

        $holder = SeparateConnection::open();
        $holder->beginTransaction();
        $holder->prepare('SELECT id FROM organizations WHERE id = ? FOR NO KEY UPDATE')->execute([$this->a->toRfc4122()]);
        try {
            $pending = $client->dispatch('PATCH', $this->member($this->repAMembership), ['role' => 'ADMIN']);
            $waiting = $this->requestsWaitingForTheOrganizationLock($holder, 1);
            $holder->prepare("UPDATE memberships SET role = 'MANAGER' WHERE id = ?")->execute([$this->adminAMembership->toRfc4122()]);
            $holder->commit();
            [$response] = ApiClient::collect($pending);
        } finally {
            if ($holder->inTransaction()) {
                $holder->rollBack();
            }
        }

        self::assertSame(1, $waiting, 'TenantGuard let it through, then it waited for the lock');
        self::assertSame(403, $response->status(), $response->raw->body);
        self::assertSame('/problems/forbidden', $response->problem());
        self::assertSame($before, $this->membership($this->repAMembership));
        self::assertSame([], $this->events($this->repAMembership));
    }

    /** API responses of the new routes carry member data: no cache may keep them (ApiCacheHeaders). */
    public function testMembershipResponsesAreNotCached(): void
    {
        $client = $this->logIn($this->adminA);
        $user = $this->fixtures->user('uncached');

        $added = $client->post($this->members(), ['email' => $user->email, 'role' => 'REP']);
        foreach ([
            'POST 201' => $added,
            'POST 409' => $client->post($this->members(), ['email' => $user->email, 'role' => 'REP']),
            'PATCH 200' => $client->patch($this->members().'/'.$added->string('membershipId'), ['role' => 'MANAGER']),
            'DELETE 204' => $client->delete($this->members().'/'.$added->string('membershipId')),
        ] as $label => $response) {
            self::assertSame((int) substr($label, -3), $response->status(), $label);
            self::assertStringContainsString('no-store', (string) $response->header('Cache-Control'), $label);
            self::assertStringContainsString('Cookie', (string) $response->header('Vary'), $label);
        }
    }

    /** The role in another organization does not count here: an ADMIN of B who is a REP of A may not administer A. */
    public function testAnAdminOfAnotherOrganizationHasOnlyTheirRoleHere(): void
    {
        $this->fixtures->member($this->a, $this->adminB, 'REP');
        $client = $this->logIn($this->adminB);
        $user = $this->fixtures->user('not-added');
        $before = $this->snapshot();

        foreach ([
            'add' => $client->post($this->members(), ['email' => $user->email, 'role' => 'ADMIN']),
            'promote' => $client->patch($this->member($this->repAMembership), ['role' => 'ADMIN']),
            'remove' => $client->delete($this->member($this->managerAMembership)),
        ] as $label => $response) {
            self::assertSame(403, $response->status(), $label);
            self::assertSame('/problems/forbidden', $response->problem(), $label);
        }
        self::assertSame($before, $this->snapshot());
    }

    /**
     * Two ADMINs add the same user at the same time: the second sees the
     * first membership under the organization lock and gets a 409, never a
     * unique constraint error.
     */
    public function testConcurrentAddsOfOneUserCreateOneMembership(): void
    {
        $second = $this->fixtures->user('second-admin');
        $this->fixtures->member($this->a, $second, 'ADMIN');
        $first = $this->logIn($this->adminA);
        $other = $this->logIn($second);
        $user = $this->fixtures->user('added-twice');

        $holder = SeparateConnection::open();
        $holder->beginTransaction();
        $holder->prepare('SELECT id FROM organizations WHERE id = ? FOR NO KEY UPDATE')->execute([$this->a->toRfc4122()]);
        try {
            $pending = [
                $first->dispatch('POST', $this->members(), ['email' => $user->email, 'role' => 'REP']),
                $other->dispatch('POST', $this->members(), ['email' => $user->email, 'role' => 'MANAGER']),
            ];
            $waiting = $this->requestsWaitingForTheOrganizationLock($holder, 2);
            $holder->rollBack();
            $responses = ApiClient::collect(...$pending);
        } finally {
            if ($holder->inTransaction()) {
                $holder->rollBack();
            }
        }

        self::assertSame(2, $waiting, 'both requests waited for the organization lock');
        $statuses = array_map(static fn (ApiResponse $r): int => $r->status(), $responses);
        sort($statuses);
        self::assertSame([201, 409], $statuses);
        $conflict = 409 === $responses[0]->status() ? $responses[0] : $responses[1];
        self::assertSame('/problems/conflict', $conflict->problem());
        $errors = $conflict->value('errors');
        self::assertIsArray($errors);
        self::assertSame(['MEMBERSHIP_EXISTS'], array_column($errors, 'code'));
        $ids = $this->fixtures->connection()->fetchFirstColumn('SELECT id FROM memberships WHERE organization_id = ? AND user_id = ?', [$this->a->toRfc4122(), $user->id->toRfc4122()]);
        self::assertCount(1, $ids);
        self::assertCount(1, $this->events(Uuid::fromString(self::string($ids[0]))));
    }

    /**
     * Two ADMINs remove each other at the same time: the second request
     * finds that its actor's membership was removed and gets the 404 that
     * TenantGuard would now answer. Exactly one ADMIN remains.
     */
    public function testConcurrentMutualRemovalsLeaveExactlyOneAdmin(): void
    {
        $second = $this->fixtures->user('second-admin');
        $secondMembership = $this->fixtures->member($this->a, $second, 'ADMIN');
        $first = $this->logIn($this->adminA);
        $other = $this->logIn($second);

        [$waiting, $responses] = $this->releasedTogether(fn (): array => [
            $first->dispatch('DELETE', $this->member($secondMembership)),
            $other->dispatch('DELETE', $this->member($this->adminAMembership)),
        ], 2);

        self::assertSame(2, $waiting, 'both requests waited for the organization lock');
        $statuses = array_map(static fn (ApiResponse $r): int => $r->status(), $responses);
        sort($statuses);
        self::assertSame([204, 404], $statuses, 'the second actor was removed meanwhile');
        self::assertSame(['ADMIN'], $this->activeAdmins());
        self::assertCount(1, [...$this->events($secondMembership), ...$this->events($this->adminAMembership)], 'one change, one audit event');
    }

    /**
     * The last two ADMINs step down at the same time, one by demoting and
     * one by removing themselves. Neither request changes the other's
     * actor, so only the ADMINs counted under the lock (BR-03) keep the
     * second from leaving the organization without an ADMIN.
     */
    public function testTheLastTwoAdminsSteppingDownAtOnceLeaveOne(): void
    {
        $second = $this->fixtures->user('second-admin');
        $secondMembership = $this->fixtures->member($this->a, $second, 'ADMIN');
        $first = $this->logIn($this->adminA);
        $other = $this->logIn($second);

        [$waiting, $responses] = $this->releasedTogether(fn (): array => [
            $first->dispatch('PATCH', $this->member($this->adminAMembership), ['role' => 'MANAGER']),
            $other->dispatch('DELETE', $this->member($secondMembership)),
        ], 2);

        self::assertSame(2, $waiting, 'both requests waited for the organization lock');
        [$demotion, $removal] = $responses;
        $conflict = 409 === $demotion->status() ? $demotion : $removal;
        $winner = 409 === $demotion->status() ? $removal : $demotion;
        self::assertSame(409, $conflict->status(), $conflict->raw->body);
        self::assertSame('/problems/conflict', $conflict->problem());
        self::assertSame([['code' => 'LAST_ADMIN']], $conflict->value('errors'));
        self::assertContains($winner->status(), [200, 204], $winner->raw->body);
        self::assertSame(['ADMIN'], $this->activeAdmins());
        self::assertCount(1, [...$this->events($secondMembership), ...$this->events($this->adminAMembership)], 'one change, one audit event');
    }

    /**
     * Two ADMINs remove the same member at the same time: the second finds
     * the membership removed under the lock and gets the 404 of a repeated
     * DELETE. The member is removed once, with one audit event.
     */
    public function testConcurrentRemovalsOfOneMemberRemoveItOnce(): void
    {
        $second = $this->fixtures->user('second-admin');
        $this->fixtures->member($this->a, $second, 'ADMIN');
        $first = $this->logIn($this->adminA);
        $other = $this->logIn($second);

        [$waiting, $responses] = $this->releasedTogether(fn (): array => [
            $first->dispatch('DELETE', $this->member($this->repAMembership)),
            $other->dispatch('DELETE', $this->member($this->repAMembership)),
        ], 2);

        self::assertSame(2, $waiting, 'both requests waited for the organization lock');
        $statuses = array_map(static fn (ApiResponse $r): int => $r->status(), $responses);
        sort($statuses);
        self::assertSame([204, 404], $statuses);
        $notFound = 404 === $responses[0]->status() ? $responses[0] : $responses[1];
        self::assertSame('/problems/not-found', $notFound->problem());
        self::assertSame('REMOVED', $this->membership($this->repAMembership)['status'] ?? null);
        self::assertSame(['membership.removed'], array_column($this->events($this->repAMembership), 'action'));
    }

    /**
     * Two ADMINs give the same member different roles at the same time: the
     * changes run one after the other, the second starts from the role the
     * first set, and the audit events form one chain that ends with the
     * stored role (no lost update).
     */
    public function testConflictingRoleChangesAreAppliedOneAfterTheOther(): void
    {
        $second = $this->fixtures->user('second-admin');
        $this->fixtures->member($this->a, $second, 'ADMIN');
        $first = $this->logIn($this->adminA);
        $other = $this->logIn($second);

        [$waiting, $responses] = $this->releasedTogether(fn (): array => [
            $first->dispatch('PATCH', $this->member($this->repAMembership), ['role' => 'MANAGER']),
            $other->dispatch('PATCH', $this->member($this->repAMembership), ['role' => 'ADMIN']),
        ], 2);

        self::assertSame(2, $waiting, 'both requests waited for the organization lock');
        self::assertSame([200, 200], array_map(static fn (ApiResponse $r): int => $r->status(), $responses));
        self::assertSame(['MANAGER', 'ADMIN'], array_map(static fn (ApiResponse $r): mixed => $r->value('role'), $responses));
        $changes = array_column($this->events($this->repAMembership), 'changes');
        self::assertCount(2, $changes);
        $start = array_values(array_filter($changes, static fn (mixed $c): bool => \is_array($c) && 'REP' === ($c['roleFrom'] ?? null)));
        self::assertCount(1, $start, 'only the first change starts from REP');
        $next = $start[0] === $changes[0] ? $changes[1] : $changes[0];
        self::assertIsArray($next);
        self::assertSame($start[0]['roleTo'], $next['roleFrom'], 'the second change starts from the first one\'s role');
        self::assertSame($next['roleTo'], $this->membership($this->repAMembership)['role'] ?? null, 'the stored role is the last change\'s');
    }

    /** An ADMIN removed while their request waits for the lock gets a 404, as their next request would. */
    public function testAnActorRemovedWhileWaitingIsNotFound(): void
    {
        $second = $this->fixtures->user('second-admin');
        $this->fixtures->member($this->a, $second, 'ADMIN');
        $client = $this->logIn($this->adminA);
        $before = $this->membership($this->repAMembership);

        $holder = SeparateConnection::open();
        $holder->beginTransaction();
        $holder->prepare('SELECT id FROM organizations WHERE id = ? FOR NO KEY UPDATE')->execute([$this->a->toRfc4122()]);
        try {
            $pending = $client->dispatch('DELETE', $this->member($this->repAMembership));
            $waiting = $this->requestsWaitingForTheOrganizationLock($holder, 1);
            $holder->prepare("UPDATE memberships SET status = 'REMOVED', removed_at = now() WHERE id = ?")->execute([$this->adminAMembership->toRfc4122()]);
            $holder->commit();
            [$response] = ApiClient::collect($pending);
        } finally {
            if ($holder->inTransaction()) {
                $holder->rollBack();
            }
        }

        self::assertSame(1, $waiting, 'TenantGuard let it through, then it waited for the lock');
        self::assertSame(404, $response->status(), $response->raw->body);
        self::assertSame('/problems/not-found', $response->problem());
        self::assertSame($before, $this->membership($this->repAMembership));
        self::assertSame([], $this->events($this->repAMembership));
    }

    /**
     * The lock is per organization: while A is locked, B's ADMIN changes B
     * without waiting, and the same ADMIN's request for A is the 404 of a
     * foreign organization, also without waiting and without a change.
     */
    public function testALockedOrganizationBlocksNeitherAnotherOrganizationNorItsRefusals(): void
    {
        $client = $this->logIn($this->adminB);
        $before = $this->membership($this->repAMembership);

        $holder = SeparateConnection::open();
        $holder->beginTransaction();
        $holder->prepare('SELECT id FROM organizations WHERE id = ? FOR NO KEY UPDATE')->execute([$this->a->toRfc4122()]);
        try {
            $start = microtime(true);
            $own = $client->patch('/api/v1/organizations/'.$this->b->toRfc4122().'/members/'.$this->repBMembership->toRfc4122(), ['role' => 'MANAGER']);
            $foreign = $client->patch($this->member($this->repAMembership), ['role' => 'ADMIN']);
            $elapsed = microtime(true) - $start;
            self::assertTrue($holder->inTransaction(), 'A was locked throughout');
        } finally {
            $holder->rollBack();
        }

        self::assertLessThan(5.0, $elapsed, 'neither request waited for A\'s lock');
        self::assertSame(200, $own->status(), $own->raw->body);
        self::assertSame('MANAGER', $own->value('role'));
        self::assertSame(['membership.role_changed'], array_column($this->events($this->repBMembership), 'action'));
        self::assertSame(404, $foreign->status());
        self::assertSame('/problems/not-found', $foreign->problem());
        self::assertSame($before, $this->membership($this->repAMembership));
        self::assertSame([], $this->events($this->repAMembership));
    }

    /** Broken bodies and malformed IDs are refused before anything is read or written. */
    public function testMalformedRequestsChangeNothing(): void
    {
        $client = $this->logIn($this->adminA);
        $before = $this->snapshot();

        self::assertSame(400, $client->post($this->members(), null, ['CONTENT_TYPE' => 'application/json'], '{"email":')->status(), 'broken JSON');
        self::assertSame(400, $client->patch($this->member($this->repAMembership), null, ['CONTENT_TYPE' => 'application/json'], '["ADMIN"]')->status(), 'not an object');
        foreach (['not-a-uuid', '00000000-0000-0000-0000-00000000000g', $this->repAMembership->toRfc4122().'x'] as $id) {
            self::assertSame(404, $client->patch($this->members().'/'.$id, ['role' => 'ADMIN'])->status(), 'PATCH '.$id);
            self::assertSame(404, $client->delete($this->members().'/'.$id)->status(), 'DELETE '.$id);
        }

        self::assertSame($before, $this->snapshot());
    }

    /**
     * Runs $action while the profile read of the member responses
     * (DbalUserDirectory::profiles) fails for $userId: a restrictive row
     * security policy of the schema owner that raises for that statement and
     * that user, removed afterwards. Other reads of the user, such as the
     * address lookup of an add, are not affected.
     *
     * @param callable(): ApiResponse $action
     */
    private function whileTheProfileCannotBeRead(Uuid $userId, callable $action): ApiResponse
    {
        $owner = TestDatabase::owner();
        $owner->executeStatement("CREATE FUNCTION test_profile_unavailable() RETURNS boolean LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'profile unavailable (test)'; END $$");
        $owner->executeStatement('GRANT EXECUTE ON FUNCTION test_profile_unavailable() TO flowcrm_app');
        $owner->executeStatement('CREATE POLICY test_any ON users USING (true) WITH CHECK (true)');
        $owner->executeStatement(\sprintf("CREATE POLICY test_profile_unavailable ON users AS RESTRICTIVE FOR SELECT USING (id <> '%s' OR strpos(current_query(), 'display_name FROM users WHERE id IN') = 0 OR test_profile_unavailable())", $userId->toRfc4122()));
        $owner->executeStatement('ALTER TABLE users ENABLE ROW LEVEL SECURITY');
        try {
            return $action();
        } finally {
            $owner->executeStatement('ALTER TABLE users DISABLE ROW LEVEL SECURITY');
            $owner->executeStatement('DROP POLICY test_profile_unavailable ON users');
            $owner->executeStatement('DROP POLICY test_any ON users');
            $owner->executeStatement('DROP FUNCTION test_profile_unavailable()');
            $owner->close();
        }
    }

    private function logIn(TestUser $user): ApiClient
    {
        $client = $this->client();
        $client->login($user->email, $user->password);

        return $client;
    }

    private function members(): string
    {
        return '/api/v1/organizations/'.$this->a->toRfc4122().'/members';
    }

    private function member(Uuid $membership): string
    {
        return $this->members().'/'.$membership->toRfc4122();
    }

    /** @return array<string, mixed>|null */
    private function membership(Uuid $id): ?array
    {
        $row = $this->fixtures->connection()->fetchAssociative('SELECT role, status, organization_id, user_id FROM memberships WHERE id = ?', [$id->toRfc4122()]);

        return false === $row ? null : $row;
    }

    /**
     * Every membership of both organizations and the number of membership
     * audit events: equal snapshots mean nothing changed.
     *
     * @return array{list<array<string, mixed>>, int}
     */
    private function snapshot(): array
    {
        $connection = $this->fixtures->connection();
        $rows = $connection->fetchAllAssociative('SELECT id, organization_id, user_id, role, status, removed_at FROM memberships WHERE organization_id IN (?, ?) ORDER BY id', [$this->a->toRfc4122(), $this->b->toRfc4122()]);
        $events = $connection->fetchOne("SELECT count(*) FROM audit_events WHERE entity_type = 'membership' AND organization_id IN (?, ?)", [$this->a->toRfc4122(), $this->b->toRfc4122()]);

        return [$rows, self::int($events)];
    }

    /** @return list<string> the roles of A's active ADMINs */
    private function activeAdmins(): array
    {
        return array_map(self::string(...), $this->fixtures->connection()->fetchFirstColumn("SELECT role FROM memberships WHERE organization_id = ? AND status = 'ACTIVE' AND role = 'ADMIN'", [$this->a->toRfc4122()]));
    }

    /** @return list<array{action: mixed, actor_type: mixed, actor_user_id: mixed, actor_role: mixed, organization_id: mixed, changes: mixed, request_id: mixed}> */
    private function events(Uuid $membership): array
    {
        $rows = $this->fixtures->connection()->fetchAllAssociative(
            "SELECT action, actor_type, actor_user_id, actor_role, organization_id, changes::text AS changes, request_id FROM audit_events WHERE entity_type = 'membership' AND entity_id = ? ORDER BY occurred_at, id",
            [$membership->toRfc4122()],
        );

        return array_map(static fn (array $row): array => [
            'action' => $row['action'],
            'actor_type' => $row['actor_type'],
            'actor_user_id' => $row['actor_user_id'],
            'actor_role' => $row['actor_role'],
            'organization_id' => $row['organization_id'],
            'changes' => json_decode(self::string($row['changes']), true, flags: \JSON_THROW_ON_ERROR),
            'request_id' => $row['request_id'],
        ], $rows);
    }

    /**
     * Starts the requests $dispatch returns while a separate connection holds
     * A's organization lock, waits until $expected of them wait for it and
     * releases it, so they then run one after the other in any order.
     *
     * @param callable(): list<PendingRequest> $dispatch
     *
     * @return array{int, list<ApiResponse>} the number of requests seen waiting, and the responses in the order of $dispatch
     */
    private function releasedTogether(callable $dispatch, int $expected): array
    {
        $holder = SeparateConnection::open();
        $holder->beginTransaction();
        $holder->prepare('SELECT id FROM organizations WHERE id = ? FOR NO KEY UPDATE')->execute([$this->a->toRfc4122()]);
        try {
            $pending = $dispatch();
            $waiting = $this->requestsWaitingForTheOrganizationLock($holder, $expected);
            $holder->rollBack();

            return [$waiting, ApiClient::collect(...$pending)];
        } finally {
            if ($holder->inTransaction()) {
                $holder->rollBack();
            }
        }
    }

    /**
     * Polls for up to ten seconds until $expected backends wait for a row
     * lock taken with the organization lock's statement. The observer is
     * inside a transaction, which keeps one pg_stat_activity snapshot until
     * it is cleared.
     */
    private function requestsWaitingForTheOrganizationLock(\PDO $observer, int $expected): int
    {
        $clear = $observer->prepare('SELECT pg_stat_clear_snapshot()');
        $statement = $observer->prepare("SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() AND pid <> pg_backend_pid() AND wait_event_type = 'Lock' AND query LIKE 'SELECT id FROM organizations WHERE id = % FOR NO KEY UPDATE'");
        for ($i = 0;; ++$i) {
            $clear->execute();
            $statement->execute();
            $count = (int) $statement->fetchColumn();
            if ($count >= $expected || $i >= 100) {
                return $count;
            }
            usleep(100_000);
        }
    }
}
