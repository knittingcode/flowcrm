<?php

declare(strict_types=1);

namespace App\Tests\Integration\CRM;

use App\Tests\Support\Http\ApiClient;
use App\Tests\Support\Http\ApiResponse;
use App\Tests\Support\Http\FpmApiTestCase;
use App\Tests\Support\Security\TestUser;
use Symfony\Component\Uid\Uuid;

/**
 * Accounts over the real PHP-FPM (docs/product/MVP.md, AC-02 and AC-10):
 * create, list, open, edit and archive, and that none of it crosses an
 * organization. Organization A has an ADMIN and a REP, B has its own ADMIN,
 * and one user is a member of both.
 */
final class AccountApiTest extends FpmApiTestCase
{
    private Uuid $a;
    private Uuid $b;
    private TestUser $adminA;
    private TestUser $repA;
    private TestUser $adminB;
    private TestUser $both;

    protected function setUp(): void
    {
        parent::setUp();
        $this->a = $this->fixtures->organization('alpha');
        $this->b = $this->fixtures->organization('beta');
        $this->adminA = $this->fixtures->user('admin-a');
        $this->repA = $this->fixtures->user('rep-a');
        $this->adminB = $this->fixtures->user('admin-b');
        $this->both = $this->fixtures->user('both');
        $this->fixtures->member($this->a, $this->adminA, 'ADMIN');
        $this->fixtures->member($this->a, $this->repA, 'REP');
        $this->fixtures->member($this->b, $this->adminB, 'ADMIN');
        $this->fixtures->member($this->a, $this->both, 'REP');
        $this->fixtures->member($this->b, $this->both, 'MANAGER');
    }

    public function testAnAccountIsCreatedListedOpenedAndEdited(): void
    {
        $client = $this->logIn($this->repA);

        $created = $client->post($this->accounts($this->a), ['name' => '  Acme Sp. z o.o. ', 'website' => 'https://acme.example.test', 'email' => '', 'phone' => null]);
        self::assertSame(201, $created->status(), $created->raw->body);
        $id = $created->string('id');
        self::assertTrue(Uuid::isValid($id));
        self::assertSame('Acme Sp. z o.o.', $created->value('name'));
        self::assertSame('https://acme.example.test', $created->value('website'));
        self::assertNull($created->value('email'), 'an empty optional value is stored as null');
        self::assertNull($created->value('phone'));
        self::assertNull($created->value('archivedAt'));
        self::assertSame($created->value('createdAt'), $created->value('updatedAt'));
        self::assertMatchesRegularExpression('/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/', $created->string('createdAt'));

        $list = $client->get($this->accounts($this->a));
        self::assertSame(200, $list->status());
        self::assertSame(['page' => 1, 'pageSize' => 25, 'total' => 1], $list->value('meta'));
        self::assertSame($created->json(), $list->value('data', 0));

        $opened = $client->get($this->accounts($this->a).'/'.$id);
        self::assertSame(200, $opened->status());
        self::assertSame($created->json(), $opened->json());

        $edited = $client->put($this->accounts($this->a).'/'.$id, ['name' => 'Acme SA', 'email' => 'biuro@acme.example.test', 'phone' => '+48 22 123 45 67']);
        self::assertSame(200, $edited->status(), $edited->raw->body);
        self::assertSame('Acme SA', $edited->value('name'));
        self::assertNull($edited->value('website'), 'a member left out of a PUT is cleared');
        self::assertSame('biuro@acme.example.test', $edited->value('email'));
        self::assertSame('+48 22 123 45 67', $edited->value('phone'));
        self::assertSame($edited->json(), $client->get($this->accounts($this->a).'/'.$id)->json(), 'the change is stored');

        self::assertSame(
            ['Acme SA', null, 'biuro@acme.example.test', '+48 22 123 45 67', $this->a->toRfc4122()],
            array_values((array) $this->fixtures->connection()->fetchAssociative('SELECT name, website, email, phone, organization_id FROM accounts WHERE id = ?', [$id])),
            'in the organization of the route',
        );
    }

    public function testAnonymousRequestsAreUnauthenticated(): void
    {
        $id = $this->account($this->a, 'Acme');
        $client = $this->client();

        foreach ([$client->get($this->accounts($this->a)), $client->get($this->accounts($this->a).'/'.$id), $client->post($this->accounts($this->a), ['name' => 'X']), $client->put($this->accounts($this->a).'/'.$id, ['name' => 'X']), $client->post($this->accounts($this->a).'/'.$id.'/archive')] as $response) {
            self::assertSame(401, $response->status());
            self::assertSame('/problems/unauthenticated', $response->problem());
        }
        self::assertSame('Acme', $this->nameOf($id));
    }

    /** AC-10: another organization's accounts cannot be listed, read, changed or archived; they look like unknown ones. */
    public function testAnotherOrganizationsAccountsAreNotFound(): void
    {
        $inA = $this->account($this->a, 'Alpha customer');
        $inB = $this->account($this->b, 'Beta customer');
        $client = $this->logIn($this->adminA);

        // The foreign organization in the path: the tenant itself is not found.
        foreach ([$client->get($this->accounts($this->b)), $client->get($this->accounts($this->b).'/'.$inB), $client->post($this->accounts($this->b), ['name' => 'Planted']), $client->put($this->accounts($this->b).'/'.$inB, ['name' => 'Changed']), $client->post($this->accounts($this->b).'/'.$inB.'/archive')] as $response) {
            self::assertSame(404, $response->status());
            self::assertSame('/problems/not-found', $response->problem());
        }

        // The own organization in the path with the foreign account ID (IDOR): the same answer as an unknown ID.
        $unknown = Uuid::v7()->toRfc4122();
        foreach (['get' => null, 'put' => ['name' => 'Changed'], 'archive' => null] as $action => $body) {
            $foreign = $this->act($client, $action, $this->accounts($this->a).'/'.$inB, $body);
            $missing = $this->act($client, $action, $this->accounts($this->a).'/'.$unknown, $body);
            self::assertSame(404, $foreign->status(), $action);
            self::assertSame($missing->comparable(), $foreign->comparable(), $action);
            self::assertSame(['type', 'title', 'status', 'instance', 'requestId'], array_keys($foreign->json()), 'no data');
        }

        self::assertSame('Beta customer', $this->nameOf($inB), 'unchanged');
        self::assertNull($this->fixtures->connection()->fetchOne('SELECT archived_at FROM accounts WHERE id = ?', [$inB]), 'not archived');
        self::assertSame(1, self::int($this->fixtures->connection()->fetchOne('SELECT count(*) FROM accounts WHERE organization_id = ?', [$this->b->toRfc4122()])), 'nothing planted in B');
        self::assertSame([$inA], array_column(self::rows($client->get($this->accounts($this->a))->value('data')), 'id'), 'the list has only A');
    }

    /** A member of two organizations sees each organization's accounts only under that organization. */
    public function testAMemberOfTwoOrganizationsSeesEachSeparately(): void
    {
        $inA = $this->account($this->a, 'Alpha customer');
        $inB = $this->account($this->b, 'Beta customer');
        $client = $this->logIn($this->both);

        self::assertSame([$inA], array_column(self::rows($client->get($this->accounts($this->a))->value('data')), 'id'));
        self::assertSame([$inB], array_column(self::rows($client->get($this->accounts($this->b))->value('data')), 'id'));
        self::assertSame(404, $client->get($this->accounts($this->a).'/'.$inB)->status());
        self::assertSame(404, $client->put($this->accounts($this->b).'/'.$inA, ['name' => 'Moved'])->status());
        self::assertSame('Alpha customer', $this->nameOf($inA));
    }

    /** The organization cannot be forged through the body, the query or a header. */
    public function testTheOrganizationComesOnlyFromThePath(): void
    {
        $client = $this->logIn($this->adminA);

        foreach (['organizationId', 'organization_id', 'id', 'archivedAt', 'createdAt'] as $member) {
            $response = $client->post($this->accounts($this->a), ['name' => 'Forged', $member => $this->b->toRfc4122()]);
            self::assertSame(422, $response->status(), $member);
            self::assertSame([['pointer' => '/'.$member, 'code' => 'UNKNOWN_FIELD']], $response->value('errors'), $member);
        }
        $query = $client->get($this->accounts($this->a).'?organizationId='.$this->b->toRfc4122());
        self::assertSame(422, $query->status());
        self::assertSame([['parameter' => 'organizationId', 'code' => 'UNKNOWN_PARAMETER']], $query->value('errors'));

        $header = $client->post($this->accounts($this->a), ['name' => 'With a header'], ['HTTP_X_ORGANIZATION_ID' => $this->b->toRfc4122()]);
        self::assertSame(201, $header->status());
        self::assertSame($this->a->toRfc4122(), $this->fixtures->connection()->fetchOne('SELECT organization_id FROM accounts WHERE id = ?', [$header->string('id')]), 'still A');
        self::assertSame(0, self::int($this->fixtures->connection()->fetchOne('SELECT count(*) FROM accounts WHERE organization_id = ?', [$this->b->toRfc4122()])));
    }

    public function testInvalidDetailsAreRefusedWithACodePerMember(): void
    {
        $client = $this->logIn($this->adminA);
        $id = $this->account($this->a, 'Acme');
        $cases = [
            [['name' => '   '], [['pointer' => '/name', 'code' => 'BLANK']]],
            [['name' => str_repeat('a', 201)], [['pointer' => '/name', 'code' => 'TOO_LONG']]],
            [['name' => "Ac\u{0}me"], [['pointer' => '/name', 'code' => 'INVALID_CHARACTERS']]],
            [['name' => 'Acme', 'website' => 'javascript:alert(1)', 'email' => 'nobody', 'phone' => 'abc'], [['pointer' => '/website', 'code' => 'INVALID_URL'], ['pointer' => '/email', 'code' => 'INVALID_EMAIL'], ['pointer' => '/phone', 'code' => 'INVALID_PHONE']]],
            [['name' => 1], [['pointer' => '/name', 'code' => 'INVALID_TYPE']]],
            [['name' => 'Acme', 'website' => ['x']], [['pointer' => '/website', 'code' => 'INVALID_TYPE']]],
        ];
        foreach ($cases as [$body, $errors]) {
            foreach ([$client->post($this->accounts($this->a), $body), $client->put($this->accounts($this->a).'/'.$id, $body)] as $response) {
                self::assertSame(422, $response->status(), $response->raw->body);
                self::assertSame('/problems/validation-error', $response->problem());
                self::assertSame($errors, $response->value('errors'));
            }
        }
        $empty = $client->post($this->accounts($this->a), raw: '{}', params: ['CONTENT_TYPE' => 'application/json']);
        self::assertSame(422, $empty->status());
        self::assertSame([['pointer' => '/name', 'code' => 'REQUIRED']], $empty->value('errors'));
        self::assertSame(400, $client->post($this->accounts($this->a), raw: '[]', params: ['CONTENT_TYPE' => 'application/json'])->status(), 'not a JSON object');
        self::assertSame(415, $client->post($this->accounts($this->a), raw: 'name=Acme', params: ['CONTENT_TYPE' => 'application/x-www-form-urlencoded'])->status());

        self::assertSame('Acme', $this->nameOf($id), 'unchanged');
        self::assertSame(1, self::int($this->fixtures->connection()->fetchOne('SELECT count(*) FROM accounts WHERE organization_id = ?', [$this->a->toRfc4122()])), 'nothing created');
    }

    /** Unsafe requests need the CSRF token of the session, like every other one. */
    public function testWritesNeedTheCsrfToken(): void
    {
        $id = $this->account($this->a, 'Acme');
        $client = $this->logIn($this->adminA);
        $client->useCsrfToken(null);

        foreach ([$client->post($this->accounts($this->a), ['name' => 'X']), $client->put($this->accounts($this->a).'/'.$id, ['name' => 'X']), $client->post($this->accounts($this->a).'/'.$id.'/archive')] as $response) {
            self::assertSame(403, $response->status());
            self::assertSame('/problems/csrf-invalid', $response->problem());
        }
        self::assertSame('Acme', $this->nameOf($id));
        self::assertSame(1, self::int($this->fixtures->connection()->fetchOne('SELECT count(*) FROM accounts WHERE organization_id = ?', [$this->a->toRfc4122()])));
    }

    /** account.archive is for ADMIN and MANAGER; an archived account leaves the list, stays readable and cannot be edited. */
    public function testArchivingNeedsThePermissionAndEndsEditing(): void
    {
        $id = $this->account($this->a, 'Acme');
        $kept = $this->account($this->a, 'Kept');
        $rep = $this->logIn($this->repA);

        $refused = $rep->post($this->accounts($this->a).'/'.$id.'/archive');
        self::assertSame(403, $refused->status());
        self::assertSame('/problems/forbidden', $refused->problem());
        self::assertNull($this->fixtures->connection()->fetchOne('SELECT archived_at FROM accounts WHERE id = ?', [$id]));

        $admin = $this->logIn($this->adminA);
        self::assertSame(204, $admin->post($this->accounts($this->a).'/'.$id.'/archive')->status());
        self::assertSame(204, $admin->post($this->accounts($this->a).'/'.$id.'/archive')->status(), 'archiving again changes nothing');

        $list = $rep->get($this->accounts($this->a));
        self::assertSame([$kept], array_column(self::rows($list->value('data')), 'id'), 'the archived account is not listed');
        self::assertSame(1, $list->value('meta', 'total'));
        $opened = $rep->get($this->accounts($this->a).'/'.$id);
        self::assertSame(200, $opened->status());
        self::assertIsString($opened->value('archivedAt'));

        $edit = $rep->put($this->accounts($this->a).'/'.$id, ['name' => 'Renamed']);
        self::assertSame(409, $edit->status());
        self::assertSame('/problems/conflict', $edit->problem());
        self::assertSame('Acme', $this->nameOf($id));
    }

    /** The list is ordered by name regardless of case, then by ID, and its pages neither overlap nor miss a row. */
    public function testTheListIsOrderedByNameAndPaged(): void
    {
        $ids = [];
        foreach (['delta', 'Alpha', 'charlie', 'Bravo', 'alpha'] as $name) {
            $ids[$name] = $this->account($this->a, $name);
        }
        $client = $this->logIn($this->adminA);

        $all = self::rows($client->get($this->accounts($this->a).'?pageSize=100')->value('data'));
        $alphas = [$ids['Alpha'], $ids['alpha']];
        sort($alphas, \SORT_STRING);
        self::assertSame([...$alphas, $ids['Bravo'], $ids['charlie'], $ids['delta']], array_column($all, 'id'));

        $paged = [];
        foreach ([1, 2, 3] as $page) {
            $response = $client->get($this->accounts($this->a).'?pageSize=2&page='.$page);
            self::assertSame(['page' => $page, 'pageSize' => 2, 'total' => 5], $response->value('meta'));
            $paged = [...$paged, ...array_column(self::rows($response->value('data')), 'id')];
        }
        self::assertSame(array_column($all, 'id'), $paged);
        self::assertSame([], $client->get($this->accounts($this->a).'?page=9')->value('data'));
        self::assertSame(422, $client->get($this->accounts($this->a).'?pageSize=101')->status());
    }

    /** Every change is audited with the actor and the changed fields, never their values; a rejected or unchanged request writes nothing. */
    public function testChangesAreAuditedWithoutValues(): void
    {
        $client = $this->logIn($this->adminA);
        $id = $client->post($this->accounts($this->a), ['name' => 'Acme', 'email' => 'private@acme.example.test'])->string('id');
        $client->put($this->accounts($this->a).'/'.$id, ['name' => 'Acme', 'email' => 'private@acme.example.test']);
        $client->put($this->accounts($this->a).'/'.$id, ['name' => 'Acme SA', 'phone' => '+48 22 123 45 67']);
        $client->put($this->accounts($this->a).'/'.$id, ['name' => '']);
        $client->post($this->accounts($this->a).'/'.$id.'/archive');
        $client->post($this->accounts($this->a).'/'.$id.'/archive');

        $events = $this->fixtures->connection()->fetchAllAssociative(
            'SELECT action, actor_type, actor_user_id, actor_role, organization_id, entity_type, changes::text AS changes, ip, request_id IS NOT NULL AS has_request FROM audit_events WHERE entity_id = ? ORDER BY occurred_at, id',
            [$id],
        );
        self::assertSame(['account.created', 'account.updated', 'account.archived'], array_column($events, 'action'));
        foreach ($events as $event) {
            self::assertSame(['user', $this->adminA->id->toRfc4122(), 'ADMIN', $this->a->toRfc4122(), 'account', null, true], [$event['actor_type'], $event['actor_user_id'], $event['actor_role'], $event['organization_id'], $event['entity_type'], $event['ip'], $event['has_request']]);
            self::assertStringNotContainsString('acme', strtolower(self::string($event['changes'])), 'no values');
        }
        self::assertSame(['fields' => ['name', 'email', 'phone']], json_decode(self::string($events[1]['changes']), true));
    }

    public function testAnAccountSurvivesANewSession(): void
    {
        $first = $this->logIn($this->adminA);
        $id = $first->post($this->accounts($this->a), ['name' => 'Persistent'])->string('id');
        self::assertSame(204, $first->post('/api/v1/auth/logout')->status());
        self::assertSame(401, $first->get($this->accounts($this->a).'/'.$id)->status());

        self::assertSame('Persistent', $this->logIn($this->adminA)->get($this->accounts($this->a).'/'.$id)->value('name'));
    }

    private function accounts(Uuid $organization): string
    {
        return '/api/v1/organizations/'.$organization->toRfc4122().'/accounts';
    }

    /** An account written directly, as the runtime role. */
    private function account(Uuid $organization, string $name): string
    {
        $id = Uuid::v7()->toRfc4122();
        $this->fixtures->connection()->insert('accounts', ['id' => $id, 'organization_id' => $organization->toRfc4122(), 'name' => $name, 'created_at' => '2026-11-16 08:00:00+00', 'updated_at' => '2026-11-16 08:00:00+00']);

        return $id;
    }

    private function nameOf(string $id): string
    {
        return self::string($this->fixtures->connection()->fetchOne('SELECT name FROM accounts WHERE id = ?', [$id]));
    }

    /** @param array<string, mixed>|null $body */
    private function act(ApiClient $client, string $action, string $uri, ?array $body): ApiResponse
    {
        return match ($action) {
            'get' => $client->get($uri),
            'put' => $client->put($uri, $body ?? []),
            default => $client->post($uri.'/archive'),
        };
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

    private function logIn(TestUser $user): ApiClient
    {
        $client = $this->client();
        $client->login($user->email, $user->password);

        return $client;
    }
}
