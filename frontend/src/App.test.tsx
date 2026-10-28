import { render, screen, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter } from 'react-router';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { App } from './App.tsx';
import { AuthProvider } from './auth/AuthProvider.tsx';
import { anonymous, fakeApi, json, problem, session } from './test/fakeApi.ts';

const status = json(200, { service: 'flowcrm-api', apiVersion: 'v1', databaseTime: '2026-10-23T10:00:00Z' });

function renderAt(path: string) {
  return render(
    <MemoryRouter initialEntries={[path]}>
      <AuthProvider>
        <App />
      </AuthProvider>
    </MemoryRouter>,
  );
}

const organization = (permissions: string[], role = 'REP') =>
  json(200, { id: 'org-a', name: 'Alpha', currency: 'EUR', timezone: 'Europe/Warsaw', membership: { id: 'm-1', role, permissions } });

const members = json(200, {
  data: [
    { membershipId: 'm-1', userId: 'u-1', displayName: 'Ada Tester', role: 'REP' },
    { membershipId: 'm-2', userId: 'u-2', displayName: 'Grace Tester', role: 'ADMIN', email: 'grace@example.test' },
  ],
  meta: { page: 1, pageSize: 25, total: 2 },
});

describe('App', () => {
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it('sends an anonymous visitor to the login and back to the page they asked for', async () => {
    const calls = fakeApi({
      'GET /api/v1/auth/session': anonymous(),
      'GET /api/v1/system/status': status,
      'POST /api/v1/auth/login': json(200, session()),
      'GET /api/v1/organizations/org-a': organization(['organization.view', 'membership.list']),
      'GET /api/v1/organizations/org-a/members?page=1': members,
    });
    renderAt('/o/org-a');

    expect(await screen.findByRole('heading', { name: 'Sign in' })).toBeInTheDocument();
    await userEvent.type(screen.getByLabelText('E-mail address'), 'ada@example.test');
    await userEvent.type(screen.getByLabelText('Password'), 'correct horse battery staple');
    await userEvent.click(screen.getByRole('button', { name: 'Sign in' }));

    expect(await screen.findByRole('heading', { name: 'Alpha' })).toBeInTheDocument();
    expect(calls.find((c) => c.path === '/api/v1/auth/login')?.body).toEqual({ email: 'ada@example.test', password: 'correct horse battery staple' });
    expect(calls.find((c) => c.path === '/api/v1/auth/login')?.headers['X-CSRF-Token']).toBeUndefined();
  });

  it('shows one generic message for a failed login and clears the password', async () => {
    fakeApi({ 'GET /api/v1/auth/session': anonymous(), 'GET /api/v1/system/status': status, 'POST /api/v1/auth/login': problem(401, 'invalid-credentials') });
    renderAt('/login');

    await userEvent.type(await screen.findByLabelText('E-mail address'), 'ada@example.test');
    await userEvent.type(screen.getByLabelText('Password'), 'wrong');
    await userEvent.click(screen.getByRole('button', { name: 'Sign in' }));

    const alert = await screen.findByRole('alert');
    expect(alert).toHaveTextContent('The e-mail address or the password is wrong.');
    expect(alert).toHaveFocus();
    expect(screen.getByLabelText('Password')).toHaveValue('');
  });

  it('tells how long to wait after too many attempts', async () => {
    fakeApi({ 'GET /api/v1/auth/session': anonymous(), 'GET /api/v1/system/status': status, 'POST /api/v1/auth/login': problem(429, 'too-many-requests', { 'Retry-After': '840' }) });
    renderAt('/login');

    await userEvent.type(await screen.findByLabelText('E-mail address'), 'ada@example.test');
    await userEvent.type(screen.getByLabelText('Password'), 'x');
    await userEvent.click(screen.getByRole('button', { name: 'Sign in' }));

    expect(await screen.findByRole('alert')).toHaveTextContent('Too many failed attempts. Try again in 14 minutes.');
  });

  it('never follows an unsafe returnTo', async () => {
    fakeApi({
      'GET /api/v1/auth/session': anonymous(),
      'GET /api/v1/system/status': status,
      'POST /api/v1/auth/login': json(200, session({ memberships: [] })),
    });
    renderAt('/login?returnTo=%2F%2Fevil.example%2Fsteal');

    await userEvent.type(await screen.findByLabelText('E-mail address'), 'ada@example.test');
    await userEvent.type(screen.getByLabelText('Password'), 'correct horse battery staple');
    await userEvent.click(screen.getByRole('button', { name: 'Sign in' }));

    expect(await screen.findByText(/not a member of any organization/)).toBeInTheDocument();
  });

  it('goes straight to the only organization and hides e-mail addresses without the permission', async () => {
    fakeApi({
      'GET /api/v1/auth/session': json(200, session()),
      'GET /api/v1/organizations/org-a': organization(['organization.view', 'membership.list']),
      'GET /api/v1/organizations/org-a/members?page=1': members,
    });
    renderAt('/');

    const table = await screen.findByRole('table');
    expect(within(table).getAllByRole('columnheader').map((h) => h.textContent)).toEqual(['Name', 'Role']);
    expect(within(table).queryByText('grace@example.test')).not.toBeInTheDocument();
  });

  it('shows e-mail addresses with the permission', async () => {
    fakeApi({
      'GET /api/v1/auth/session': json(200, session()),
      'GET /api/v1/organizations/org-a': organization(['organization.view', 'membership.list', 'membership.view_email'], 'MANAGER'),
      'GET /api/v1/organizations/org-a/members?page=1': members,
    });
    renderAt('/o/org-a');

    const table = await screen.findByRole('table');
    expect(within(table).getAllByRole('columnheader').map((h) => h.textContent)).toEqual(['Name', 'Role', 'E-mail address']);
    expect(within(table).getByText('grace@example.test')).toBeInTheDocument();
  });

  it('lets a member of several organizations choose', async () => {
    fakeApi({
      'GET /api/v1/auth/session': json(
        200,
        session({
          memberships: [
            { organizationId: 'org-a', organizationName: 'Alpha', membershipId: 'm-1', role: 'REP', permissions: [] },
            { organizationId: 'org-b', organizationName: 'Beta', membershipId: 'm-2', role: 'MANAGER', permissions: [] },
          ],
        }),
      ),
    });
    renderAt('/');

    expect(await screen.findByRole('heading', { name: 'Organizations' })).toBeInTheDocument();
    const main = screen.getByRole('main');
    expect(within(main).getByRole('link', { name: 'Alpha' })).toHaveAttribute('href', '/o/org-a');
    expect(within(main).getByRole('link', { name: 'Beta' })).toHaveAttribute('href', '/o/org-b');
  });

  it('shows the same "not found" for a foreign organization as for an unknown page', async () => {
    fakeApi({
      'GET /api/v1/auth/session': json(200, session()),
      'GET /api/v1/organizations/org-x': problem(404, 'not-found'),
      'GET /api/v1/organizations/org-x/members?page=1': problem(404, 'not-found'),
    });
    renderAt('/o/org-x');
    expect(await screen.findByRole('heading', { name: 'Not found' })).toBeInTheDocument();
  });

  it('returns to the login when the server has ended the session', async () => {
    fakeApi({
      'GET /api/v1/auth/session': json(200, session()),
      'GET /api/v1/organizations/org-a': problem(401, 'unauthenticated'),
      'GET /api/v1/organizations/org-a/members?page=1': problem(401, 'unauthenticated'),
      'GET /api/v1/system/status': status,
    });
    renderAt('/o/org-a');

    expect(await screen.findByRole('heading', { name: 'Sign in' })).toBeInTheDocument();
    expect(screen.getByText('Your session has ended. Please sign in again.')).toBeInTheDocument();
  });

  it('signs out with the CSRF token and shows the login', async () => {
    const calls = fakeApi({
      'GET /api/v1/auth/session': json(200, session()),
      'GET /api/v1/organizations/org-a': organization(['organization.view', 'membership.list']),
      'GET /api/v1/organizations/org-a/members?page=1': members,
      'POST /api/v1/auth/logout': new Response(null, { status: 204 }),
      'GET /api/v1/system/status': status,
    });
    renderAt('/o/org-a');

    await userEvent.click(await screen.findByRole('button', { name: 'Sign out' }));

    expect(await screen.findByRole('heading', { name: 'Sign in' })).toBeInTheDocument();
    expect(calls.find((c) => c.path === '/api/v1/auth/logout')?.headers['X-CSRF-Token']).toBe('token-1');
  });

  describe('a sign-out that does not complete keeps the user signed in and says so', () => {
    const failures: [string, () => Response][] = [
      ['the connection fails', () => {
        throw new TypeError('Failed to fetch');
      }],
      ['the API answers 500', () => problem(500, 'internal-error')],
      ['the edge answers 502', () => new Response(null, { status: 502 })],
      ['the CSRF token is refused again after reading the session', () => problem(403, 'csrf-invalid')],
    ];
    it.each(failures)('when %s', async (_, answer) => {
      fakeApi({
        'GET /api/v1/auth/session': json(200, session()),
        'GET /api/v1/organizations/org-a': organization(['organization.view', 'membership.list']),
        'GET /api/v1/organizations/org-a/members?page=1': members,
        'POST /api/v1/auth/logout': answer,
      });
      renderAt('/o/org-a');

      await userEvent.click(await screen.findByRole('button', { name: 'Sign out' }));

      expect(await screen.findByRole('alert')).toHaveTextContent('Signing out did not complete. You may still be signed in, so try again.');
      expect(screen.getByRole('button', { name: 'Sign out' })).toBeEnabled();
      expect(screen.getByRole('heading', { name: 'Alpha' })).toBeInTheDocument();
      expect(screen.queryByRole('heading', { name: 'Sign in' })).not.toBeInTheDocument();
    });
  });

  it('treats a 401 to the sign-out as a session that has already ended', async () => {
    fakeApi({
      'GET /api/v1/auth/session': json(200, session()),
      'GET /api/v1/organizations/org-a': organization(['organization.view', 'membership.list']),
      'GET /api/v1/organizations/org-a/members?page=1': members,
      'POST /api/v1/auth/logout': problem(401, 'unauthenticated'),
      'GET /api/v1/system/status': status,
    });
    renderAt('/o/org-a');

    await userEvent.click(await screen.findByRole('button', { name: 'Sign out' }));

    expect(await screen.findByRole('heading', { name: 'Sign in' })).toBeInTheDocument();
    expect(screen.queryByText('Signing out did not complete', { exact: false })).not.toBeInTheDocument();
  });

  it('shows a forbidden answer without data', async () => {
    fakeApi({
      'GET /api/v1/auth/session': json(200, session()),
      'GET /api/v1/organizations/org-a': problem(403, 'forbidden'),
      'GET /api/v1/organizations/org-a/members?page=1': problem(403, 'forbidden'),
    });
    renderAt('/o/org-a');

    expect(await screen.findByRole('alert')).toHaveTextContent('You do not have permission to see this.');
  });
});
