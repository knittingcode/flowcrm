import { afterEach, describe, expect, it, vi } from 'vitest';
import { fakeApi, json } from '../test/fakeApi.ts';
import { setCsrfToken } from './client.ts';
import { addMember, changeRole, isConflict, removeMember } from './memberships.ts';

const member = { membershipId: 'm/2', userId: 'u-2', displayName: 'Grace Tester', role: 'MANAGER', email: 'grace@example.test' };

function conflict(code: string) {
  return json(409, { type: '/problems/conflict', title: 'Conflict', status: 409, instance: '/api', requestId: 'r-1', errors: [{ code }] });
}

describe('membership requests', () => {
  afterEach(() => {
    vi.unstubAllGlobals();
    setCsrfToken(null);
  });

  it('sends each change with the CSRF token, a JSON body and encoded identifiers', async () => {
    const calls = fakeApi({
      'POST /api/v1/organizations/org%2Fa%3F/members': json(201, member),
      'PATCH /api/v1/organizations/org%2Fa%3F/members/m%2F2': json(200, member),
      'DELETE /api/v1/organizations/org%2Fa%3F/members/m%2F2': new Response(null, { status: 204 }),
    });
    setCsrfToken('token-1');

    await expect(addMember('org/a?', { email: 'grace@example.test', role: 'MANAGER' })).resolves.toEqual(member);
    await expect(changeRole('org/a?', 'm/2', 'MANAGER')).resolves.toEqual(member);
    await expect(removeMember('org/a?', 'm/2')).resolves.toBeNull();

    expect(calls.map((c) => [c.method, c.headers['X-CSRF-Token'], c.body])).toEqual([
      ['POST', 'token-1', { email: 'grace@example.test', role: 'MANAGER' }],
      ['PATCH', 'token-1', { role: 'MANAGER' }],
      ['DELETE', 'token-1', undefined],
    ]);
    expect(calls[0]?.headers['Content-Type']).toBe('application/json');
  });

  it('reads conflicts by their code, and validation errors with pointer and code', async () => {
    fakeApi({
      'PATCH /api/v1/organizations/org-a/members/m-1': conflict('LAST_ADMIN'),
      'POST /api/v1/organizations/org-a/members': [
        conflict('MEMBERSHIP_EXISTS'),
        json(422, {
          type: '/problems/validation-error',
          title: 'Invalid',
          status: 422,
          instance: '/api',
          requestId: 'r-2',
          errors: [
            { pointer: '/email', code: 'UNKNOWN_USER' },
            { pointer: '/role', code: 'INVALID_ROLE' },
            { pointer: '/x', code: 'UNKNOWN_FIELD' },
          ],
        }),
      ],
    });

    const lastAdmin: unknown = await changeRole('org-a', 'm-1', 'REP').catch((e: unknown) => e);
    expect(isConflict(lastAdmin, 'LAST_ADMIN')).toBe(true);
    expect(isConflict(lastAdmin, 'MEMBERSHIP_EXISTS')).toBe(false);

    const exists: unknown = await addMember('org-a', { email: 'a@example.test', role: 'REP' }).catch((e: unknown) => e);
    expect(isConflict(exists, 'MEMBERSHIP_EXISTS')).toBe(true);

    await expect(addMember('org-a', { email: 'a@example.test', role: 'REP' })).rejects.toMatchObject({
      status: 422,
      errors: [
        { pointer: '/email', code: 'UNKNOWN_USER' },
        { pointer: '/role', code: 'INVALID_ROLE' },
        { pointer: '/x', code: 'UNKNOWN_FIELD' },
      ],
    });
  });

  it('refuses an answer that is not a member', async () => {
    fakeApi({ 'PATCH /api/v1/organizations/org-a/members/m-1': json(200, { membershipId: 'm-1' }) });
    await expect(changeRole('org-a', 'm-1', 'REP')).rejects.toThrow('Unexpected response from the API');
  });
});
