<?php

declare(strict_types=1);

namespace App\Tests\Integration\Security;

use App\Tests\Support\Http\ApiClient;
use App\Tests\Support\Http\FpmApiTestCase;
use App\Tests\Support\Security\TestUser;
use Symfony\Component\Uid\Uuid;

/**
 * Tenant isolation and the provisional role matrix over the real PHP-FPM
 * (FCRM-002 TI-01, TI-04, TI-05, NT-10 to NT-12 as amended by FCRM-003 C-05;
 * ADR-019). Organization A has an ADMIN, a MANAGER, a REP, a user who is REP
 * in A and MANAGER in B, and a removed member; B has its own ADMIN.
 */
final class TenantAuthorizationTest extends FpmApiTestCase
{
    private Uuid $a;
    private Uuid $b;
    private TestUser $adminA;
    private TestUser $managerA;
    private TestUser $repA;
    private TestUser $both;
    private TestUser $removed;
    private TestUser $adminB;
    private Uuid $managerAMembership;
    private Uuid $bothMembershipInB;
    private Uuid $adminBMembership;

    protected function setUp(): void
    {
        parent::setUp();
        $this->a = $this->fixtures->organization('alpha');
        $this->b = $this->fixtures->organization('beta');
        $this->adminA = $this->fixtures->user('admin-a');
        $this->managerA = $this->fixtures->user('manager-a');
        $this->repA = $this->fixtures->user('rep-a');
        $this->both = $this->fixtures->user('both');
        $this->removed = $this->fixtures->user('removed');
        $this->adminB = $this->fixtures->user('admin-b');
        $this->fixtures->member($this->a, $this->adminA, 'ADMIN');
        $this->managerAMembership = $this->fixtures->member($this->a, $this->managerA, 'MANAGER');
        $this->fixtures->member($this->a, $this->repA, 'REP');
        $this->fixtures->member($this->a, $this->both, 'REP');
        $this->bothMembershipInB = $this->fixtures->member($this->b, $this->both, 'MANAGER');
        $this->fixtures->removeMembership($this->fixtures->member($this->a, $this->removed, 'REP'));
        $this->adminBMembership = $this->fixtures->member($this->b, $this->adminB, 'ADMIN');
    }

    public function testAnonymousRequestsAreUnauthenticatedBeforeAnyTenantLookup(): void
    {
        $client = $this->client();
        foreach ([$this->a, Uuid::v7()] as $organization) {
            foreach (['', '/members', '/members/'.$this->managerAMembership->toRfc4122()] as $suffix) {
                $response = $client->get('/api/v1/organizations/'.$organization->toRfc4122().$suffix);
                self::assertSame(401, $response->status(), $suffix);
                self::assertSame('/problems/unauthenticated', $response->problem());
            }
        }
    }

    /** NT-10 as amended (C-05): another organization looks exactly like one that does not exist. */
    public function testAForeignOrganizationIsIndistinguishableFromAnUnknownOne(): void
    {
        $client = $this->logIn($this->adminB);
        foreach (['', '/members', '/members/'.$this->managerAMembership->toRfc4122()] as $suffix) {
            $foreign = $client->get('/api/v1/organizations/'.$this->a->toRfc4122().$suffix);
            $unknown = $client->get('/api/v1/organizations/'.Uuid::v7()->toRfc4122().$suffix);

            self::assertSame(404, $foreign->status(), $suffix);
            self::assertSame('/problems/not-found', $foreign->problem());
            self::assertSame($unknown->comparable(), $foreign->comparable(), $suffix);
            self::assertSame(['type', 'title', 'status', 'instance', 'requestId'], array_keys($foreign->json()), 'no data');
        }
    }

    public function testAUserWithoutAnyMembershipSeesNoOrganization(): void
    {
        $client = $this->logIn($this->fixtures->user('outsider'));

        self::assertSame([], $client->get('/api/v1/me')->json()['memberships']);
        self::assertSame(404, $client->get('/api/v1/organizations/'.$this->a->toRfc4122())->status());
    }

    public function testMembersSeeTheirOrganizationWithTheirRole(): void
    {
        $response = $this->logIn($this->repA)->get('/api/v1/organizations/'.$this->a->toRfc4122());

        self::assertSame(200, $response->status());
        self::assertSame($this->a->toRfc4122(), $response->value('id'));
        $membershipId = $response->value('membership', 'id');
        self::assertIsString($membershipId);
        self::assertTrue(Uuid::isValid($membershipId));
        self::assertSame('REP', $response->value('membership', 'role'));
        self::assertSame(['organization.view', 'membership.list'], $response->value('membership', 'permissions'));
    }

    /** The provisional matrix: the directory for every role, e-mail addresses for ADMIN and MANAGER only. */
    public function testEmailAddressesNeedThePermission(): void
    {
        foreach ([[$this->adminA, true], [$this->managerA, true], [$this->repA, false]] as [$user, $withEmail]) {
            $response = $this->logIn($user)->get('/api/v1/organizations/'.$this->a->toRfc4122().'/members');
            self::assertSame(200, $response->status());
            $members = $response->json()['data'];
            self::assertIsArray($members);
            self::assertCount(4, $members, 'the four active members (the removed one is not listed)');
            foreach ($members as $member) {
                self::assertIsArray($member);
                self::assertSame($withEmail, \array_key_exists('email', $member), $user->email);
            }
            self::assertSame(['page' => 1, 'pageSize' => 25, 'total' => 4], $response->json()['meta']);
        }
    }

    /** A user in two organizations has the role of each, separately; IDs of one are 404 in the other (NT-11). */
    public function testAUserInTwoOrganizationsHasTheRoleOfEach(): void
    {
        $client = $this->logIn($this->both);
        $memberships = $client->get('/api/v1/me')->json()['memberships'];
        self::assertIsArray($memberships);
        self::assertCount(2, $memberships);

        $inA = $client->get('/api/v1/organizations/'.$this->a->toRfc4122().'/members')->json()['data'];
        $inB = $client->get('/api/v1/organizations/'.$this->b->toRfc4122().'/members')->json()['data'];
        self::assertIsArray($inA);
        self::assertIsArray($inB);
        self::assertArrayNotHasKey('email', (array) $inA[0], 'REP in A');
        self::assertArrayHasKey('email', (array) $inB[0], 'MANAGER in B');

        self::assertSame(404, $client->get('/api/v1/organizations/'.$this->a->toRfc4122().'/members/'.$this->adminBMembership->toRfc4122())->status(), 'a B membership under A');
        self::assertSame(200, $client->get('/api/v1/organizations/'.$this->b->toRfc4122().'/members/'.$this->adminBMembership->toRfc4122())->status());
    }

    /** IDOR: membership IDs of another organization, guessed or malformed ones are all 404. */
    public function testGuessedResourceIdsAreNotFound(): void
    {
        $client = $this->logIn($this->adminA);
        $base = '/api/v1/organizations/'.$this->a->toRfc4122().'/members/';

        self::assertSame(200, $client->get($base.$this->managerAMembership->toRfc4122())->status());
        $foreign = $client->get($base.$this->bothMembershipInB->toRfc4122());
        $unknown = $client->get($base.Uuid::v7()->toRfc4122());
        self::assertSame(404, $foreign->status());
        self::assertSame($unknown->comparable(), $foreign->comparable());
        foreach (['not-a-uuid', strtoupper($this->managerAMembership->toRfc4122()), '00000000-0000-0000-0000-000000000000'] as $id) {
            self::assertSame(404, $client->get($base.$id)->status(), $id);
        }
        foreach (['not-a-uuid', strtoupper($this->a->toRfc4122())] as $id) {
            self::assertSame(404, $client->get('/api/v1/organizations/'.$id)->status(), $id);
        }
    }

    /** TI-05: the organization comes only from the path; IDs in the query, a header or the body are not used. */
    public function testClientSuppliedOrganizationIdsAreIgnoredOrRefused(): void
    {
        $client = $this->logIn($this->repA);
        $path = '/api/v1/organizations/'.$this->a->toRfc4122().'/members';

        $query = $client->get($path.'?organizationId='.$this->b->toRfc4122());
        self::assertSame(422, $query->status());
        self::assertSame([['parameter' => 'organizationId', 'code' => 'UNKNOWN_PARAMETER']], $query->json()['errors']);

        $header = $client->get($path, ['HTTP_X_ORGANIZATION_ID' => $this->b->toRfc4122()]);
        self::assertSame(200, $header->status());
        self::assertSame(4, $header->value('meta', 'total'), 'still A');
        self::assertSame(404, $client->get('/api/v1/organizations/'.$this->b->toRfc4122(), ['HTTP_X_ORGANIZATION_ID' => $this->a->toRfc4122()])->status());

        $body = $client->post('/api/v1/me/password', ['currentPassword' => 'x', 'newPassword' => 'long enough password', 'organizationId' => $this->a->toRfc4122()]);
        self::assertSame(422, $body->status());
        self::assertSame([['pointer' => '/organizationId', 'code' => 'UNKNOWN_FIELD']], $body->json()['errors']);
    }

    /** TI-04 / NT-12: a removed membership ends access on the next request of the same session. */
    public function testRemovingAMembershipTakesEffectOnTheNextRequest(): void
    {
        $client = $this->logIn($this->managerA);
        self::assertSame(200, $client->get('/api/v1/organizations/'.$this->a->toRfc4122())->status());

        $this->fixtures->removeMembership($this->managerAMembership);

        self::assertSame(404, $client->get('/api/v1/organizations/'.$this->a->toRfc4122())->status());
        self::assertSame(404, $client->get('/api/v1/organizations/'.$this->a->toRfc4122().'/members')->status());
        self::assertSame([], $client->get('/api/v1/me')->json()['memberships']);
        self::assertSame(404, $this->logIn($this->removed)->get('/api/v1/organizations/'.$this->a->toRfc4122())->status(), 'a member removed before the login');
    }

    /** TI-04: a demotion takes effect on the next request; nothing about the role is cached. */
    public function testADemotionTakesEffectOnTheNextRequest(): void
    {
        $client = $this->logIn($this->managerA);
        $path = '/api/v1/organizations/'.$this->a->toRfc4122().'/members';
        self::assertArrayHasKey('email', (array) $client->get($path)->value('data', 0));

        $this->fixtures->changeRole($this->managerAMembership, 'REP');

        self::assertArrayNotHasKey('email', (array) $client->get($path)->value('data', 0));
        $organization = $client->get('/api/v1/organizations/'.$this->a->toRfc4122());
        self::assertSame('REP', $organization->value('membership', 'role'));
        self::assertSame(['organization.view', 'membership.list'], $organization->value('membership', 'permissions'));
    }

    public function testPaginationIsValidated(): void
    {
        $client = $this->logIn($this->adminA);
        $path = '/api/v1/organizations/'.$this->a->toRfc4122().'/members';

        $page = $client->get($path.'?page=2&pageSize=2')->json();
        self::assertSame(['page' => 2, 'pageSize' => 2, 'total' => 4], $page['meta']);
        self::assertIsArray($page['data']);
        self::assertCount(2, $page['data']);
        foreach (['pageSize=101' => 'OUT_OF_RANGE', 'page=0' => 'OUT_OF_RANGE', 'page=abc' => 'INVALID_TYPE', 'pageSize[]=1' => 'INVALID_TYPE'] as $query => $code) {
            $response = $client->get($path.'?'.$query);
            self::assertSame(422, $response->status(), $query);
            self::assertSame($code, $response->value('errors', 0, 'code'), $query);
        }
    }

    /** Pages past the end are empty, out-of-range sizes are refused, and pages follow one stable order (oldest membership first). */
    public function testPaginationEdgesAndOrder(): void
    {
        $client = $this->logIn($this->adminA);
        $path = '/api/v1/organizations/'.$this->a->toRfc4122().'/members';

        $beyond = $client->get($path.'?page=99&pageSize=2');
        self::assertSame(200, $beyond->status());
        self::assertSame([], $beyond->value('data'));
        self::assertSame(['page' => 99, 'pageSize' => 2, 'total' => 4], $beyond->value('meta'));
        foreach (['pageSize=0' => 'OUT_OF_RANGE', 'page=-1' => 'INVALID_TYPE'] as $query => $code) {
            $response = $client->get($path.'?'.$query);
            self::assertSame(422, $response->status(), $query);
            self::assertSame($code, $response->value('errors', 0, 'code'), $query);
        }

        $all = self::ids($client->get($path.'?pageSize=100')->value('data'));
        $paged = [...self::ids($client->get($path.'?page=1&pageSize=2')->value('data')), ...self::ids($client->get($path.'?page=2&pageSize=2')->value('data'))];
        self::assertSame($all, $paged, 'the pages do not overlap and miss nothing');
        self::assertSame($all, self::ids($client->get($path.'?pageSize=100')->value('data')), 'the order is stable');
        $names = array_column(self::rows($client->get($path.'?pageSize=100')->value('data')), 'displayName');
        self::assertSame([$this->adminA->displayName, $this->managerA->displayName, $this->repA->displayName, $this->both->displayName], $names, 'oldest membership first');
    }

    /** @return list<array<mixed>> */
    private static function rows(mixed $data): array
    {
        self::assertIsArray($data);
        $rows = [];
        foreach ($data as $row) {
            self::assertIsArray($row);
            $rows[] = $row;
        }

        return $rows;
    }

    /** @return list<mixed> */
    private static function ids(mixed $data): array
    {
        return array_column(self::rows($data), 'membershipId');
    }

    private function logIn(TestUser $user): ApiClient
    {
        $client = $this->client();
        $client->login($user->email, $user->password);

        return $client;
    }
}
