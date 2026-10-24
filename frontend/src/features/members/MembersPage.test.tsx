import { render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter } from 'react-router';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { App } from '../../App.tsx';
import { AuthProvider } from '../../auth/AuthProvider.tsx';
import { type Call, fakeApi, json, problem, session } from '../../test/fakeApi.ts';

const ORG = '/api/v1/organizations/org-a';
const MEMBERS = `${ORG}/members?page=1`;
const ADMIN = ['organization.view', 'membership.list', 'membership.view_email', 'membership.add', 'membership.change_role', 'membership.remove'];
const MANAGER = ['organization.view', 'membership.list', 'membership.view_email'];
const REP = ['organization.view', 'membership.list'];
const status = json(200, { service: 'flowcrm-api', apiVersion: 'v1', databaseTime: '2026-10-23T10:00:00Z' });

function adminSession(memberships?: unknown[]) {
  return json(
    200,
    session({
      memberships: memberships ?? [{ organizationId: 'org-a', organizationName: 'Alpha', membershipId: 'm-1', role: 'ADMIN', permissions: ADMIN }],
    }),
  );
}

function organization(permissions: string[], role = 'ADMIN') {
  return json(200, { id: 'org-a', name: 'Alpha', currency: 'EUR', timezone: 'Europe/Warsaw', membership: { id: 'm-1', role, permissions } });
}

interface Row {
  membershipId: string;
  displayName: string;
  role: string;
  email?: string;
}

const ada: Row = { membershipId: 'm-1', displayName: 'Ada Tester', role: 'ADMIN', email: 'ada@example.test' };
const grace: Row = { membershipId: 'm-2', displayName: 'Grace Tester', role: 'REP', email: 'grace@example.test' };
const withoutEmail = (r: Row): Row => ({ membershipId: r.membershipId, displayName: r.displayName, role: r.role });

function members(rows: Row[], meta = { page: 1, pageSize: 25, total: rows.length }) {
  return json(200, { data: rows.map((r) => ({ userId: `u-${r.membershipId}`, ...r })), meta });
}

const conflict = (code: string) =>
  json(409, { type: '/problems/conflict', title: 'Conflict', status: 409, instance: '/api', requestId: 'r-409', errors: [{ code }] });

function renderAt(path: string) {
  return render(
    <MemoryRouter initialEntries={[path]}>
      <AuthProvider>
        <App />
      </AuthProvider>
    </MemoryRouter>,
  );
}

const count = (calls: Call[], method: string, path: string) => calls.filter((c) => c.method === method && c.path === path).length;

/**
 * Holds the n-th request `method path` (1-based) until `release` is called;
 * every other request is answered by the fake API at once.
 */
function hold(method: string, path: string, n: number): { release: () => void } {
  let release: () => void = () => undefined;
  const gate = new Promise<void>((resolve) => {
    release = resolve;
  });
  const fake = globalThis.fetch;
  let seen = 0;
  vi.stubGlobal('fetch', async (input: RequestInfo | URL, init?: RequestInit) => {
    if ((init?.method ?? 'GET') === method && input === path) {
      seen += 1;
      if (seen === n) {
        await gate;
      }
    }
    return fake(input, init);
  });
  return {
    release: () => {
      release();
    },
  };
}

const holdGet = (path: string, n: number) => hold('GET', path, n);

describe('MembersPage', () => {
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it('is linked from the organization page', async () => {
    fakeApi({ 'GET /api/v1/auth/session': adminSession(), [`GET ${ORG}`]: organization(ADMIN), [`GET ${MEMBERS}`]: members([ada, grace]) });
    renderAt('/o/org-a');

    expect(await screen.findByRole('link', { name: 'Open the members page' })).toHaveAttribute('href', '/o/org-a/members');
  });

  it.each([
    ['ADMIN', ADMIN, true, true],
    ['MANAGER', MANAGER, false, true],
    ['REP', REP, false, false],
  ] as const)('shows the controls a %s has, and e-mail addresses only with the permission', async (role, permissions, controls, emails) => {
    fakeApi({
      'GET /api/v1/auth/session': adminSession(),
      [`GET ${ORG}`]: organization([...permissions], role),
      [`GET ${MEMBERS}`]: members(emails ? [ada, grace] : [ada, grace].map(withoutEmail)),
    });
    renderAt('/o/org-a/members');

    const table = await screen.findByRole('table', { name: '2 members' });
    const headers = within(table).getAllByRole('columnheader').map((h) => h.textContent);
    expect(headers).toEqual(['Name', 'Role', ...(emails ? ['E-mail address'] : []), ...(controls ? ['Actions'] : [])]);
    expect(within(table).queryByText('grace@example.test') !== null).toBe(emails);
    expect(screen.queryByRole('form', { name: 'Add a member' }) !== null).toBe(controls);
    expect(screen.queryAllByRole('button', { name: /^Change role of / })).toHaveLength(controls ? 2 : 0);
    expect(screen.queryAllByRole('button', { name: /^Remove / })).toHaveLength(controls ? 2 : 0);
    expect(within(table).getByRole('rowheader', { name: 'Ada Tester (you)' })).toBeInTheDocument();
  });

  it('adds a member with the CSRF token and shows the list the server has afterwards', async () => {
    const calls = fakeApi({
      'GET /api/v1/auth/session': adminSession(),
      [`GET ${ORG}`]: organization(ADMIN),
      [`GET ${MEMBERS}`]: [members([ada]), members([ada, grace])],
      [`POST ${ORG}/members`]: json(201, { ...grace, userId: 'u-2', role: 'MANAGER' }),
    });
    renderAt('/o/org-a/members');

    await userEvent.type(await screen.findByLabelText('E-mail address of the user'), 'grace@example.test');
    await userEvent.selectOptions(screen.getByLabelText('Role'), 'MANAGER');
    await userEvent.click(screen.getByRole('button', { name: 'Add member' }));

    expect(await screen.findByRole('status')).toHaveTextContent('grace@example.test was added as MANAGER.');
    expect(await screen.findByRole('rowheader', { name: 'Grace Tester' })).toBeInTheDocument();
    const post = calls.find((c) => c.method === 'POST');
    expect(post?.body).toEqual({ email: 'grace@example.test', role: 'MANAGER' });
    expect(post?.headers['X-CSRF-Token']).toBe('token-1');
    expect(count(calls, 'GET', MEMBERS)).toBe(2);
    expect(count(calls, 'GET', ORG)).toBe(2);
    expect(screen.getByLabelText('E-mail address of the user')).toHaveValue('');
  });

  it('disables the submit button while the request is pending', async () => {
    fakeApi({
      'GET /api/v1/auth/session': adminSession(),
      [`GET ${ORG}`]: organization(ADMIN),
      [`GET ${MEMBERS}`]: members([ada]),
      [`POST ${ORG}/members`]: json(201, { ...grace, userId: 'u-2' }),
    });
    let answer: (value: unknown) => void = () => undefined;
    const answered = new Promise((resolve) => {
      answer = resolve;
    });
    const fake = globalThis.fetch;
    vi.stubGlobal('fetch', async (input: RequestInfo | URL, init?: RequestInit) => {
      if (init?.method === 'POST') {
        await answered;
      }
      return fake(input, init);
    });
    renderAt('/o/org-a/members');

    await userEvent.type(await screen.findByLabelText('E-mail address of the user'), 'grace@example.test');
    await userEvent.click(screen.getByRole('button', { name: 'Add member' }));

    expect(screen.getByRole('button', { name: 'Adding…' })).toBeDisabled();
    answer(null);
    expect(await screen.findByRole('button', { name: 'Add member' })).toBeEnabled();
  });

  it('ties validation errors to their inputs, summarises them and focuses the first invalid input', async () => {
    const calls = fakeApi({
      'GET /api/v1/auth/session': adminSession(),
      [`GET ${ORG}`]: organization(ADMIN),
      [`GET ${MEMBERS}`]: members([ada]),
      [`POST ${ORG}/members`]: json(422, {
        type: '/problems/validation-error',
        title: 'Invalid',
        status: 422,
        instance: '/api',
        requestId: 'r-422',
        errors: [
          { pointer: '/role', code: 'INVALID_ROLE' },
          { pointer: '/email', code: 'UNKNOWN_USER' },
        ],
      }),
    });
    renderAt('/o/org-a/members');

    await userEvent.type(await screen.findByLabelText('E-mail address of the user'), 'nobody@example.test');
    await userEvent.click(screen.getByRole('button', { name: 'Add member' }));

    const email = screen.getByLabelText('E-mail address of the user');
    await waitFor(() => {
      expect(email).toHaveFocus();
    });
    expect(email).toHaveAttribute('aria-invalid', 'true');
    expect(email).toHaveAccessibleDescription('No user has this e-mail address. Only existing users can be added.');
    expect(screen.getByLabelText('Role')).toHaveAccessibleDescription('Choose one of the roles ADMIN, MANAGER or REP.');
    const summary = screen.getByRole('alert');
    expect(summary).toHaveTextContent('The member could not be added');
    expect(within(summary).getAllByRole('listitem')).toHaveLength(2);
    expect(count(calls, 'GET', MEMBERS)).toBe(1);
  });

  it('explains a membership that exists already and changes nothing', async () => {
    const calls = fakeApi({
      'GET /api/v1/auth/session': adminSession(),
      [`GET ${ORG}`]: organization(ADMIN),
      [`GET ${MEMBERS}`]: members([ada, grace]),
      [`POST ${ORG}/members`]: conflict('MEMBERSHIP_EXISTS'),
    });
    renderAt('/o/org-a/members');

    await userEvent.type(await screen.findByLabelText('E-mail address of the user'), 'grace@example.test');
    await userEvent.click(screen.getByRole('button', { name: 'Add member' }));

    const alert = await screen.findByRole('alert');
    expect(alert).toHaveTextContent('This user already has a membership in this organization (active or removed). Nothing was changed.');
    await waitFor(() => {
      expect(alert).toHaveFocus();
    });
    await waitFor(() => {
      expect(count(calls, 'GET', MEMBERS)).toBe(2);
    });
    expect(screen.getByRole('table', { name: '2 members' })).toBeInTheDocument();
  });

  it('refuses to demote the last admin without changing the list, after a warning about oneself', async () => {
    const calls = fakeApi({
      'GET /api/v1/auth/session': adminSession(),
      [`GET ${ORG}`]: organization(ADMIN),
      [`GET ${MEMBERS}`]: members([ada, grace]),
      [`PATCH ${ORG}/members/m-1`]: conflict('LAST_ADMIN'),
    });
    renderAt('/o/org-a/members');

    const change = await screen.findByRole('button', { name: 'Change role of Ada Tester' });
    expect(change).toBeDisabled();
    await userEvent.selectOptions(screen.getByLabelText('New role for Ada Tester'), 'REP');
    expect(change).toHaveAccessibleDescription(/This is your own membership/);
    await userEvent.click(change);

    expect(await screen.findByRole('alert')).toHaveTextContent('An organization needs at least one admin.');
    expect(calls.find((c) => c.method === 'PATCH')?.body).toEqual({ role: 'REP' });
    await waitFor(() => {
      expect(count(calls, 'GET', MEMBERS)).toBe(2);
    });
    const row = screen.getByRole('rowheader', { name: 'Ada Tester (you)' }).closest('tr');
    expect(row).not.toBeNull();
    expect(within(row as HTMLElement).getAllByRole('cell')[0]).toHaveTextContent('ADMIN');
    expect(screen.getByLabelText('New role for Ada Tester')).toHaveValue('ADMIN');
  });

  it('changes the role of another member and announces it', async () => {
    const calls = fakeApi({
      'GET /api/v1/auth/session': adminSession(),
      [`GET ${ORG}`]: organization(ADMIN),
      [`GET ${MEMBERS}`]: [members([ada, grace]), members([ada, { ...grace, role: 'MANAGER' }])],
      [`PATCH ${ORG}/members/m-2`]: json(200, { ...grace, userId: 'u-2', role: 'MANAGER' }),
    });
    renderAt('/o/org-a/members');

    await userEvent.selectOptions(await screen.findByLabelText('New role for Grace Tester'), 'MANAGER');
    await userEvent.click(screen.getByRole('button', { name: 'Change role of Grace Tester' }));

    expect(await screen.findByRole('status')).toHaveTextContent('The role of Grace Tester is now MANAGER.');
    expect(calls.find((c) => c.method === 'PATCH')?.headers['X-CSRF-Token']).toBe('token-1');
    await waitFor(() => {
      expect(screen.getByLabelText('New role for Grace Tester')).toHaveValue('MANAGER');
    });
  });

  it('reports a refused permission and shows the controls of the role the server reports now', async () => {
    const calls = fakeApi({
      'GET /api/v1/auth/session': adminSession(),
      [`GET ${ORG}`]: [organization(ADMIN), organization(REP, 'REP')],
      [`GET ${MEMBERS}`]: members([ada, grace]),
      [`DELETE ${ORG}/members/m-2`]: problem(403, 'forbidden'),
    });
    renderAt('/o/org-a/members');

    await userEvent.click(await screen.findByRole('button', { name: 'Remove Grace Tester' }));
    await userEvent.click(screen.getByRole('button', { name: 'Yes, remove Grace Tester' }));

    expect(await screen.findByRole('alert')).toHaveTextContent('You do not have permission to do this.');
    await waitFor(() => {
      expect(screen.queryByRole('form', { name: 'Add a member' })).not.toBeInTheDocument();
    });
    expect(screen.queryAllByRole('button', { name: /^Remove / })).toHaveLength(0);
    expect(calls.find((c) => c.method === 'DELETE')?.headers['X-CSRF-Token']).toBe('token-1');
    expect(count(calls, 'GET', ORG)).toBe(2);
  });

  it('reloads the list when the member was changed by someone else', async () => {
    fakeApi({
      'GET /api/v1/auth/session': adminSession(),
      [`GET ${ORG}`]: organization(ADMIN),
      [`GET ${MEMBERS}`]: [members([ada, grace]), members([ada])],
      [`PATCH ${ORG}/members/m-2`]: problem(404, 'not-found'),
    });
    renderAt('/o/org-a/members');

    await userEvent.selectOptions(await screen.findByLabelText('New role for Grace Tester'), 'ADMIN');
    await userEvent.click(screen.getByRole('button', { name: 'Change role of Grace Tester' }));

    expect(await screen.findByRole('alert')).toHaveTextContent('This member was changed or removed by someone else; the list was reloaded');
    await waitFor(() => {
      expect(screen.queryByRole('rowheader', { name: 'Grace Tester' })).not.toBeInTheDocument();
    });
  });

  it('shows "not found" when the organization itself is gone after a refusal', async () => {
    fakeApi({
      'GET /api/v1/auth/session': adminSession(),
      [`GET ${ORG}`]: [organization(ADMIN), problem(404, 'not-found')],
      [`GET ${MEMBERS}`]: [members([ada, grace]), problem(404, 'not-found')],
      [`DELETE ${ORG}/members/m-2`]: problem(404, 'not-found'),
    });
    renderAt('/o/org-a/members');

    await userEvent.click(await screen.findByRole('button', { name: 'Remove Grace Tester' }));
    await userEvent.click(screen.getByRole('button', { name: 'Yes, remove Grace Tester' }));

    expect(await screen.findByRole('heading', { name: 'Not found' })).toBeInTheDocument();
  });

  it.each([
    [problem(429, 'too-many-requests', { 'Retry-After': '30' }), 'Too many requests. Try again in 30 seconds.'],
    [problem(429, 'too-many-requests', { 'Retry-After': '90' }), 'Too many requests. Try again in 2 minutes.'],
    [problem(500, 'internal-error'), 'The change could not be saved (request 0192f0c4-7d1e-7b8a-9f3c-2b4d6e8f0a1c).'],
  ])('reports other failures inline (%#)', async (answer, message) => {
    const calls = fakeApi({
      'GET /api/v1/auth/session': adminSession(),
      [`GET ${ORG}`]: organization(ADMIN),
      [`GET ${MEMBERS}`]: members([ada, grace]),
      [`POST ${ORG}/members`]: answer,
    });
    renderAt('/o/org-a/members');

    await userEvent.type(await screen.findByLabelText('E-mail address of the user'), 'x@example.test');
    await userEvent.click(screen.getByRole('button', { name: 'Add member' }));

    expect(await screen.findByRole('alert')).toHaveTextContent(message);
    expect(count(calls, 'GET', MEMBERS)).toBe(1);
  });

  it('explains a CSRF token refused again after the retry, without reporting a missing permission', async () => {
    const calls = fakeApi({
      'GET /api/v1/auth/session': adminSession(),
      [`GET ${ORG}`]: organization(ADMIN),
      [`GET ${MEMBERS}`]: members([ada, grace]),
      [`POST ${ORG}/members`]: problem(403, 'csrf-invalid'),
    });
    renderAt('/o/org-a/members');

    await userEvent.type(await screen.findByLabelText('E-mail address of the user'), 'x@example.test');
    await userEvent.click(screen.getByRole('button', { name: 'Add member' }));

    const alert = await screen.findByRole('alert');
    expect(alert).toHaveTextContent(
      'The security token of your session could not be verified, so nothing was changed. Reload the page or sign in again, then try again.',
    );
    expect(alert).not.toHaveTextContent('permission');
    expect(alert).toHaveFocus();
    expect(count(calls, 'POST', `${ORG}/members`)).toBe(2);
    expect(count(calls, 'GET', '/api/v1/auth/session')).toBe(2);
    expect(count(calls, 'GET', MEMBERS)).toBe(1);
    expect(screen.getByRole('form', { name: 'Add a member' })).toBeInTheDocument();
  });

  it('says nothing was changed, without reloading, when the token cannot be refreshed after csrf-invalid', async () => {
    const calls = fakeApi({
      'GET /api/v1/auth/session': adminSession(),
      [`GET ${ORG}`]: organization(ADMIN),
      [`GET ${MEMBERS}`]: members([ada, grace]),
      [`POST ${ORG}/members`]: problem(403, 'csrf-invalid'),
    });
    renderAt('/o/org-a/members');
    await userEvent.type(await screen.findByLabelText('E-mail address of the user'), 'x@example.test');
    // From now on the session (and with it the token) cannot be read.
    const fake = globalThis.fetch;
    vi.stubGlobal('fetch', (input: RequestInfo | URL, init?: RequestInit) =>
      input === '/api/v1/auth/session' ? Promise.reject(new TypeError('Failed to fetch')) : fake(input, init),
    );
    await userEvent.click(screen.getByRole('button', { name: 'Add member' }));

    const alert = await screen.findByRole('alert');
    expect(alert).toHaveTextContent('The security token of your session could not be verified, so nothing was changed.');
    expect(alert).not.toHaveTextContent('not known');
    expect(alert).toHaveFocus();
    expect(count(calls, 'POST', `${ORG}/members`)).toBe(1);
    expect(count(calls, 'GET', MEMBERS)).toBe(1);
  });

  it('reloads the list when the API could not be reached, as the change may have been saved', async () => {
    const calls = fakeApi({
      'GET /api/v1/auth/session': adminSession(),
      [`GET ${ORG}`]: organization(ADMIN),
      [`GET ${MEMBERS}`]: [members([ada, grace]), members([ada])],
    });
    const fake = globalThis.fetch;
    vi.stubGlobal('fetch', (input: RequestInfo | URL, init?: RequestInit) =>
      init?.method === 'DELETE' ? Promise.reject(new TypeError('Failed to fetch')) : fake(input, init),
    );
    renderAt('/o/org-a/members');

    await userEvent.click(await screen.findByRole('button', { name: 'Remove Grace Tester' }));
    await userEvent.click(screen.getByRole('button', { name: 'Yes, remove Grace Tester' }));

    const alert = await screen.findByRole('alert');
    expect(alert).toHaveTextContent(
      'The API could not be reached, so it is not known whether the change was saved. The list was reloaded to show the current state.',
    );
    await waitFor(() => {
      expect(screen.queryByRole('rowheader', { name: 'Grace Tester' })).not.toBeInTheDocument();
    });
    expect(screen.getByRole('alert')).toHaveFocus();
    expect(count(calls, 'GET', MEMBERS)).toBe(2);
    expect(count(calls, 'GET', ORG)).toBe(2);
  });

  it.each([
    ['a body that is not JSON', () => new Response('<html>', { status: 201, headers: { 'Content-Type': 'text/html' } })],
    ['JSON of an unexpected shape', () => json(201, { unexpected: true })],
  ])('reloads the list after a success answer with %s, as the outcome is unknown', async (_, answer) => {
    const calls = fakeApi({
      'GET /api/v1/auth/session': adminSession(),
      [`GET ${ORG}`]: organization(ADMIN),
      [`GET ${MEMBERS}`]: [members([ada]), members([ada, grace])],
      [`POST ${ORG}/members`]: answer,
    });
    renderAt('/o/org-a/members');

    await userEvent.type(await screen.findByLabelText('E-mail address of the user'), 'grace@example.test');
    await userEvent.click(screen.getByRole('button', { name: 'Add member' }));

    const alert = await screen.findByRole('alert');
    expect(alert).toHaveTextContent(
      'The answer of the API could not be read, so it is not known whether the change was saved. The list was reloaded to show the current state.',
    );
    expect(alert).not.toHaveTextContent('could not be saved');
    expect(await screen.findByRole('rowheader', { name: 'Grace Tester' })).toBeInTheDocument();
    expect(count(calls, 'GET', MEMBERS)).toBe(2);
  });

  it.each([
    ['502 with an empty body', () => new Response('', { status: 502 }), 502],
    ['504 with an HTML body', () => new Response('<html>Gateway Timeout</html>', { status: 504, headers: { 'Content-Type': 'text/html' } }), 504],
  ])('treats a server error that did not come from the API (%s) as an unknown outcome and reloads', async (_, answer, code) => {
    const calls = fakeApi({
      'GET /api/v1/auth/session': adminSession(),
      [`GET ${ORG}`]: organization(ADMIN),
      [`GET ${MEMBERS}`]: [members([ada, grace]), members([ada, { ...grace, role: 'MANAGER' }])],
      [`PATCH ${ORG}/members/m-2`]: answer,
    });
    renderAt('/o/org-a/members');

    await userEvent.selectOptions(await screen.findByLabelText('New role for Grace Tester'), 'MANAGER');
    await userEvent.click(screen.getByRole('button', { name: 'Change role of Grace Tester' }));

    const alert = await screen.findByRole('alert');
    expect(alert).toHaveTextContent(
      `The API did not answer properly (status ${String(code)}), so it is not known whether the change was saved. The list was reloaded to show the current state.`,
    );
    expect(alert).not.toHaveTextContent('could not be saved');
    await waitFor(() => {
      expect(screen.getByLabelText('New role for Grace Tester')).toHaveValue('MANAGER');
    });
    expect(count(calls, 'GET', MEMBERS)).toBe(2);
  });

  it('keeps the controls disabled and the table busy until the list after a change has been read', async () => {
    fakeApi({
      'GET /api/v1/auth/session': adminSession(),
      [`GET ${ORG}`]: organization(ADMIN),
      [`GET ${MEMBERS}`]: [members([ada, grace]), members([ada])],
      [`DELETE ${ORG}/members/m-2`]: new Response(null, { status: 204 }),
    });
    const reload = holdGet(MEMBERS, 2);
    renderAt('/o/org-a/members');

    await userEvent.click(await screen.findByRole('button', { name: 'Remove Grace Tester' }));
    await userEvent.click(screen.getByRole('button', { name: 'Yes, remove Grace Tester' }));

    expect(await screen.findByRole('status')).toHaveTextContent('Grace Tester was removed.');
    // The removed member is still shown until the server's list arrives, but cannot be acted on.
    expect(screen.getByRole('table')).toHaveAttribute('aria-busy', 'true');
    expect(screen.getByRole('button', { name: 'Remove Grace Tester' })).toBeDisabled();
    expect(screen.getByRole('button', { name: 'Remove Ada Tester' })).toBeDisabled();

    reload.release();
    await waitFor(() => {
      expect(screen.queryByRole('rowheader', { name: 'Grace Tester' })).not.toBeInTheDocument();
    });
    expect(screen.getByRole('table')).toHaveAttribute('aria-busy', 'false');
    expect(screen.getByRole('button', { name: 'Remove Ada Tester' })).toBeEnabled();
  });

  it('returns to the login when the session has ended', async () => {
    fakeApi({
      'GET /api/v1/auth/session': adminSession(),
      'GET /api/v1/system/status': status,
      [`GET ${ORG}`]: organization(ADMIN),
      [`GET ${MEMBERS}`]: members([ada, grace]),
      [`POST ${ORG}/members`]: problem(401, 'unauthenticated'),
    });
    renderAt('/o/org-a/members');

    await userEvent.type(await screen.findByLabelText('E-mail address of the user'), 'x@example.test');
    await userEvent.click(screen.getByRole('button', { name: 'Add member' }));

    expect(await screen.findByRole('heading', { name: 'Sign in' })).toBeInTheDocument();
    expect(screen.getByText('Your session has ended. Please sign in again.')).toBeInTheDocument();
  });

  it('after removing oneself, reads the session again and goes to the start page', async () => {
    const calls = fakeApi({
      'GET /api/v1/auth/session': [adminSession(), adminSession([])],
      [`GET ${ORG}`]: organization(ADMIN),
      [`GET ${MEMBERS}`]: members([ada, grace]),
      [`DELETE ${ORG}/members/m-1`]: new Response(null, { status: 204 }),
    });
    renderAt('/o/org-a/members');

    await userEvent.click(await screen.findByRole('button', { name: 'Remove Ada Tester' }));
    expect(screen.getByRole('group', { name: 'Remove Ada Tester from Alpha?' })).toHaveTextContent(
      'You are removing yourself: you will lose access to this organization immediately.',
    );
    await userEvent.click(screen.getByRole('button', { name: 'Yes, remove Ada Tester' }));

    expect(await screen.findByText(/not a member of any organization/)).toBeInTheDocument();
    expect(count(calls, 'GET', '/api/v1/auth/session')).toBe(2);
    expect(count(calls, 'GET', MEMBERS)).toBe(1);
  });

  it('moves the focus into the confirmation, and back with Cancel or Escape', async () => {
    const calls = fakeApi({
      'GET /api/v1/auth/session': adminSession(),
      [`GET ${ORG}`]: organization(ADMIN),
      [`GET ${MEMBERS}`]: members([ada, grace]),
    });
    renderAt('/o/org-a/members');

    await userEvent.click(await screen.findByRole('button', { name: 'Remove Grace Tester' }));
    const group = screen.getByRole('group', { name: 'Remove Grace Tester from Alpha?' });
    expect(within(group).getByRole('button', { name: 'Cancel' })).toHaveFocus();
    expect(group).not.toHaveTextContent('You are removing yourself');

    await userEvent.keyboard('{Escape}');
    expect(screen.queryByRole('group')).not.toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Remove Grace Tester' })).toHaveFocus();

    await userEvent.click(screen.getByRole('button', { name: 'Remove Grace Tester' }));
    await userEvent.click(screen.getByRole('button', { name: 'Cancel' }));
    expect(screen.getByRole('button', { name: 'Remove Grace Tester' })).toHaveFocus();
    expect(calls.filter((c) => c.method === 'DELETE')).toEqual([]);
  });

  it('keeps the focus in the busy confirmation while a removal runs, then moves it to the status', async () => {
    fakeApi({
      'GET /api/v1/auth/session': adminSession(),
      [`GET ${ORG}`]: organization(ADMIN),
      [`GET ${MEMBERS}`]: [members([ada, grace]), members([ada])],
      [`DELETE ${ORG}/members/m-2`]: new Response(null, { status: 204 }),
    });
    const removal = hold('DELETE', `${ORG}/members/m-2`, 1);
    renderAt('/o/org-a/members');

    await userEvent.click(await screen.findByRole('button', { name: 'Remove Grace Tester' }));
    await userEvent.click(screen.getByRole('button', { name: 'Yes, remove Grace Tester' }));

    const group = screen.getByRole('group', { name: 'Remove Grace Tester from Alpha?' });
    expect(group).toHaveFocus();
    expect(group).toHaveAttribute('aria-busy', 'true');
    expect(within(group).getByRole('button', { name: 'Yes, remove Grace Tester' })).toBeDisabled();
    expect(within(group).getByRole('button', { name: 'Cancel' })).toBeDisabled();
    // Escape cannot cancel a removal that has been sent.
    await userEvent.keyboard('{Escape}');
    expect(screen.getByRole('group', { name: 'Remove Grace Tester from Alpha?' })).toHaveFocus();

    removal.release();
    const status = await screen.findByRole('status');
    await waitFor(() => {
      expect(status).toHaveTextContent('Grace Tester was removed.');
    });
    expect(status).toHaveFocus();
    await waitFor(() => {
      expect(screen.queryByRole('group')).not.toBeInTheDocument();
    });
    expect(status).toHaveFocus();
  });

  it('closes the confirmation and moves the focus to the error message after a failed removal', async () => {
    fakeApi({
      'GET /api/v1/auth/session': adminSession(),
      [`GET ${ORG}`]: organization(ADMIN),
      [`GET ${MEMBERS}`]: members([ada, grace]),
      [`DELETE ${ORG}/members/m-2`]: problem(500, 'internal-error'),
    });
    renderAt('/o/org-a/members');

    await userEvent.click(await screen.findByRole('button', { name: 'Remove Grace Tester' }));
    await userEvent.click(screen.getByRole('button', { name: 'Yes, remove Grace Tester' }));

    const alert = await screen.findByRole('alert');
    expect(alert).toHaveTextContent('The change could not be saved');
    await waitFor(() => {
      expect(screen.queryByRole('group')).not.toBeInTheDocument();
    });
    expect(alert).toHaveFocus();
    expect(screen.getByRole('button', { name: 'Remove Grace Tester' })).toBeEnabled();
  });

  it('keeps the page in the address', async () => {
    const calls = fakeApi({
      'GET /api/v1/auth/session': adminSession(),
      [`GET ${ORG}`]: organization(REP, 'REP'),
      [`GET ${ORG}/members?page=1`]: members([ada], { page: 1, pageSize: 1, total: 2 }),
      [`GET ${ORG}/members?page=2`]: members([grace], { page: 2, pageSize: 1, total: 2 }),
    });
    renderAt('/o/org-a/members?page=2');

    expect(await screen.findByRole('table', { name: '2 members, page 2 of 2' })).toBeInTheDocument();
    expect(screen.getByRole('rowheader', { name: 'Grace Tester' })).toBeInTheDocument();
    expect(calls.some((c) => c.path === `${ORG}/members?page=1`)).toBe(false);

    await userEvent.click(screen.getByRole('button', { name: 'Previous' }));
    expect(await screen.findByRole('table', { name: '2 members, page 1 of 2' })).toBeInTheDocument();
    expect(screen.getByRole('rowheader', { name: 'Ada Tester (you)' })).toBeInTheDocument();
  });

  it('labels the page it shows, not the one being read, and marks the table busy meanwhile', async () => {
    fakeApi({
      'GET /api/v1/auth/session': adminSession(),
      [`GET ${ORG}`]: organization(ADMIN),
      [`GET ${ORG}/members?page=1`]: members([ada], { page: 1, pageSize: 1, total: 2 }),
      [`GET ${ORG}/members?page=2`]: members([grace], { page: 2, pageSize: 1, total: 2 }),
    });
    const next = holdGet(`${ORG}/members?page=2`, 1);
    renderAt('/o/org-a/members');

    await userEvent.click(await screen.findByRole('button', { name: 'Next' }));

    const table = screen.getByRole('table', { name: '2 members, page 1 of 2' });
    expect(table).toHaveAttribute('aria-busy', 'true');
    expect(screen.getByRole('navigation', { name: 'Member pages' })).toHaveTextContent('Page 1 of 2');
    expect(screen.getByRole('button', { name: 'Remove Ada Tester' })).toBeDisabled();

    next.release();
    expect(await screen.findByRole('table', { name: '2 members, page 2 of 2' })).toHaveAttribute('aria-busy', 'false');
    expect(screen.getByRole('rowheader', { name: 'Grace Tester' })).toBeInTheDocument();
  });

  it.each(['0', '-1', 'abc', '1e3'])('reads the page %j as the first page', async (value) => {
    const calls = fakeApi({ 'GET /api/v1/auth/session': adminSession(), [`GET ${ORG}`]: organization(REP, 'REP'), [`GET ${MEMBERS}`]: members([ada]) });
    renderAt(`/o/org-a/members?page=${value}`);

    expect(await screen.findByRole('table')).toBeInTheDocument();
    expect(calls.filter((c) => c.path.includes('/members')).map((c) => c.path)).toEqual([MEMBERS]);
  });
});
