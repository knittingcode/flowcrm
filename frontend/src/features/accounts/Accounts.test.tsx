import { render, screen, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter } from 'react-router';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { App } from '../../App.tsx';
import { AuthProvider } from '../../auth/AuthProvider.tsx';
import { fakeApi, json, problem, session } from '../../test/fakeApi.ts';

function renderAt(path: string) {
  return render(
    <MemoryRouter initialEntries={[path]}>
      <AuthProvider>
        <App />
      </AuthProvider>
    </MemoryRouter>,
  );
}

const acme = {
  id: 'acc-1',
  name: 'Acme',
  website: 'https://acme.example.test',
  email: 'office@acme.example.test',
  phone: null,
  createdAt: '2026-11-16T08:00:00Z',
  updatedAt: '2026-11-16T08:00:00Z',
  archivedAt: null,
};

const page = (data: unknown[], total = data.length) => json(200, { data, meta: { page: 1, pageSize: 25, total } });

const member = (permissions: string[], role = 'REP') =>
  json(200, session({ memberships: [{ organizationId: 'org-a', organizationName: 'Alpha', membershipId: 'm-1', role, permissions }] }));

const validation = (errors: { pointer: string; code: string }[]) =>
  json(422, { type: '/problems/validation-error', title: 'Unprocessable Content', status: 422, instance: '/api', requestId: 'r-1', errors });

describe('accounts', () => {
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it('lists the accounts with links and reaches them from the navigation', async () => {
    fakeApi({
      'GET /api/v1/auth/session': json(200, session()),
      'GET /api/v1/organizations/org-a': json(200, { id: 'org-a', name: 'Alpha', currency: 'EUR', timezone: 'Europe/Warsaw', membership: { id: 'm-1', role: 'REP', permissions: [] } }),
      'GET /api/v1/organizations/org-a/members?page=1': json(200, { data: [], meta: { page: 1, pageSize: 25, total: 0 } }),
      'GET /api/v1/organizations/org-a/accounts?page=1': page([acme, { ...acme, id: 'acc-2', name: 'Beta', email: null }]),
    });
    renderAt('/o/org-a');

    await userEvent.click(await screen.findByRole('link', { name: 'Accounts' }));

    const table = await screen.findByRole('table');
    expect(within(table).getByRole('link', { name: 'Acme' })).toHaveAttribute('href', '/o/org-a/accounts/acc-1');
    expect(within(table).getByRole('link', { name: 'Beta' })).toHaveAttribute('href', '/o/org-a/accounts/acc-2');
    expect(within(table).getByText('office@acme.example.test')).toBeInTheDocument();
    expect(screen.getByText('2 accounts')).toBeInTheDocument();
  });

  it('shows an empty state and adds the first account', async () => {
    const calls = fakeApi({
      'GET /api/v1/auth/session': json(200, session()),
      'GET /api/v1/organizations/org-a/accounts?page=1': [page([]), page([acme])],
      'POST /api/v1/organizations/org-a/accounts': json(201, acme),
    });
    renderAt('/o/org-a/accounts');

    expect(await screen.findByText('There are no accounts yet. Add the first one below.')).toBeInTheDocument();
    await userEvent.type(screen.getByLabelText('Name'), 'Acme');
    await userEvent.type(screen.getByLabelText('Website (optional)'), 'https://acme.example.test');
    await userEvent.click(screen.getByRole('button', { name: 'Add account' }));

    expect(await screen.findByRole('link', { name: 'Acme' })).toBeInTheDocument();
    expect(screen.getByRole('status')).toHaveTextContent('The account “Acme” was added.');
    expect(screen.getByLabelText('Name')).toHaveValue('');
    const post = calls.find((c) => c.method === 'POST');
    expect(post?.body).toEqual({ name: 'Acme', website: 'https://acme.example.test', email: null, phone: null });
    expect(post?.headers['X-CSRF-Token']).toBe('token-1');
  });

  it('shows the validation answer next to each field and keeps what was typed', async () => {
    fakeApi({
      'GET /api/v1/auth/session': json(200, session()),
      'GET /api/v1/organizations/org-a/accounts?page=1': page([]),
      'POST /api/v1/organizations/org-a/accounts': validation([
        { pointer: '/name', code: 'BLANK' },
        { pointer: '/website', code: 'INVALID_URL' },
      ]),
    });
    renderAt('/o/org-a/accounts');

    await userEvent.type(await screen.findByLabelText('Website (optional)'), 'acme');
    await userEvent.click(screen.getByRole('button', { name: 'Add account' }));

    expect(await screen.findByText('This is required.')).toBeInTheDocument();
    expect(screen.getByText('Enter a web address that starts with http:// or https://.')).toBeInTheDocument();
    expect(screen.getByLabelText('Name')).toBeInvalid();
    expect(screen.getByLabelText('Website (optional)')).toHaveValue('acme');
    expect(screen.getByLabelText('E-mail address (optional)')).toBeValid();
  });

  it('has no form for a member who may only view', async () => {
    fakeApi({
      'GET /api/v1/auth/session': member(['organization.view', 'account.view']),
      'GET /api/v1/organizations/org-a/accounts?page=1': page([acme]),
    });
    renderAt('/o/org-a/accounts');

    expect(await screen.findByRole('link', { name: 'Acme' })).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Add account' })).not.toBeInTheDocument();
  });

  it('opens an account and saves a change', async () => {
    const changed = { ...acme, name: 'Acme SA', phone: '+48 22 123 45 67', updatedAt: '2026-11-16T09:00:00Z' };
    const calls = fakeApi({
      'GET /api/v1/auth/session': json(200, session()),
      'GET /api/v1/organizations/org-a/accounts/acc-1': json(200, acme),
      'PUT /api/v1/organizations/org-a/accounts/acc-1': json(200, changed),
    });
    renderAt('/o/org-a/accounts/acc-1');

    expect(await screen.findByRole('heading', { name: 'Acme' })).toBeInTheDocument();
    expect(screen.getByRole('link', { name: 'https://acme.example.test' })).toHaveAttribute('rel', 'noreferrer noopener');
    const name = screen.getByLabelText('Name');
    expect(name).toHaveValue('Acme');
    await userEvent.clear(name);
    await userEvent.type(name, 'Acme SA');
    await userEvent.type(screen.getByLabelText('Phone (optional)'), '+48 22 123 45 67');
    await userEvent.click(screen.getByRole('button', { name: 'Save changes' }));

    expect(await screen.findByRole('heading', { name: 'Acme SA' })).toBeInTheDocument();
    expect(screen.getByRole('status')).toHaveTextContent('The changes were saved.');
    expect(calls.find((c) => c.method === 'PUT')?.body).toEqual({
      name: 'Acme SA',
      website: 'https://acme.example.test',
      email: 'office@acme.example.test',
      phone: '+48 22 123 45 67',
    });
    expect(screen.queryByRole('heading', { name: 'Archive' })).not.toBeInTheDocument();
  });

  it('archives an account after a confirmation, for a member who may', async () => {
    const calls = fakeApi({
      'GET /api/v1/auth/session': member(['organization.view', 'account.view', 'account.manage', 'account.archive'], 'MANAGER'),
      'GET /api/v1/organizations/org-a/accounts/acc-1': [json(200, acme), json(200, { ...acme, archivedAt: '2026-11-16T10:00:00Z' })],
      'POST /api/v1/organizations/org-a/accounts/acc-1/archive': new Response(null, { status: 204 }),
    });
    renderAt('/o/org-a/accounts/acc-1');

    await userEvent.click(await screen.findByRole('button', { name: 'Archive…' }));
    expect(calls.some((c) => c.method === 'POST')).toBe(false);
    await userEvent.click(screen.getByRole('button', { name: 'Archive this account' }));

    expect(await screen.findByText('This account is archived. It is no longer in the list and cannot be changed.')).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Save changes' })).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Archive…' })).not.toBeInTheDocument();
    expect(calls.find((c) => c.method === 'POST')?.headers['X-CSRF-Token']).toBe('token-1');
  });

  it('shows the same "not found" for an account of another organization as for an unknown page', async () => {
    fakeApi({
      'GET /api/v1/auth/session': json(200, session()),
      'GET /api/v1/organizations/org-a/accounts/acc-x': problem(404, 'not-found'),
    });
    renderAt('/o/org-a/accounts/acc-x');

    expect(await screen.findByRole('heading', { name: 'Not found' })).toBeInTheDocument();
  });

  it('says so when the list cannot be loaded', async () => {
    fakeApi({
      'GET /api/v1/auth/session': json(200, session()),
      'GET /api/v1/organizations/org-a/accounts?page=1': problem(500, 'internal-error'),
    });
    renderAt('/o/org-a/accounts');

    expect(await screen.findByRole('alert')).toHaveTextContent('The accounts could not be loaded (request 0192f0c4-7d1e-7b8a-9f3c-2b4d6e8f0a1c).');
  });
});
