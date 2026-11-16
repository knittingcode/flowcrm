import { useCallback, useEffect, useState } from 'react';
import { Link, useParams } from 'react-router';
import { type AccountPage, createAccount, EMPTY_DETAILS, listAccounts } from '../../api/accounts.ts';
import { ApiProblem } from '../../api/client.ts';
import { useAuth } from '../../auth/context.ts';
import { NotFoundPage } from '../../pages/NotFoundPage.tsx';
import { AccountForm } from './AccountForm.tsx';

type State =
  | { kind: 'loading' }
  | { kind: 'ready'; accounts: AccountPage }
  | { kind: 'not-found' }
  | { kind: 'forbidden' }
  | { kind: 'error'; message: string };

function stateOf(error: unknown): State {
  if (error instanceof ApiProblem && error.status === 404) {
    return { kind: 'not-found' };
  }
  if (error instanceof ApiProblem && error.status === 403) {
    return { kind: 'forbidden' };
  }
  if (error instanceof ApiProblem) {
    return { kind: 'error', message: `The accounts could not be loaded (request ${error.requestId ?? 'unknown'}).` };
  }
  return { kind: 'error', message: 'The API could not be reached.' };
}

/**
 * The accounts (customer companies) of an organization: the list, and a form
 * for a new one for members who may manage accounts. The organization comes
 * from the address; the API decides what the user may see and do.
 */
export function AccountsPage() {
  const { organizationId = '' } = useParams();
  const [page, setPage] = useState(1);

  return <AccountsView key={`${organizationId}:${String(page)}`} organizationId={organizationId} page={page} onPage={setPage} />;
}

function AccountsView({ organizationId, page, onPage }: { organizationId: string; page: number; onPage: (page: number) => void }) {
  const { state: auth } = useAuth();
  const [state, setState] = useState<State>({ kind: 'loading' });
  const [created, setCreated] = useState<string | null>(null);

  const load = useCallback(
    (signal?: AbortSignal) =>
      listAccounts(organizationId, page, signal).then(
        (accounts) => {
          setState({ kind: 'ready', accounts });
        },
        (error: unknown) => {
          if (signal?.aborted !== true) {
            setState(stateOf(error));
          }
        },
      ),
    [organizationId, page],
  );

  useEffect(() => {
    const controller = new AbortController();
    void load(controller.signal);
    return () => {
      controller.abort();
    };
  }, [load]);

  if (state.kind === 'loading') {
    return <p role="status">Loading the accounts…</p>;
  }
  if (state.kind === 'not-found') {
    return <NotFoundPage />;
  }
  if (state.kind === 'forbidden') {
    return <p role="alert">You do not have permission to see this.</p>;
  }
  if (state.kind === 'error') {
    return <p role="alert">{state.message}</p>;
  }

  const { accounts } = state;
  const pages = Math.max(1, Math.ceil(accounts.meta.total / accounts.meta.pageSize));
  const membership = auth.status === 'authenticated' ? auth.session.memberships.find((m) => m.organizationId === organizationId) : undefined;
  const mayManage = membership?.permissions.includes('account.manage') === true;

  return (
    <>
      <h1>Accounts</h1>
      {accounts.meta.total === 0 ? (
        <p>There are no accounts yet.{mayManage ? ' Add the first one below.' : ''}</p>
      ) : (
        <table>
          <caption>
            {accounts.meta.total} {accounts.meta.total === 1 ? 'account' : 'accounts'}
          </caption>
          <thead>
            <tr>
              <th scope="col">Name</th>
              <th scope="col">E-mail address</th>
              <th scope="col">Phone</th>
            </tr>
          </thead>
          <tbody>
            {accounts.data.map((account) => (
              <tr key={account.id}>
                <td>
                  <Link to={`/o/${organizationId}/accounts/${account.id}`}>{account.name}</Link>
                </td>
                <td>{account.email ?? '—'}</td>
                <td>{account.phone ?? '—'}</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
      {pages > 1 && (
        <nav aria-label="Account pages" className="pager">
          <button type="button" disabled={page <= 1} onClick={() => { onPage(page - 1); }}>
            Previous
          </button>
          <span>
            Page {page} of {pages}
          </span>
          <button type="button" disabled={page >= pages} onClick={() => { onPage(page + 1); }}>
            Next
          </button>
        </nav>
      )}
      {created !== null && <p role="status">The account “{created}” was added.</p>}
      {mayManage && (
        <AccountForm
          legend="New account"
          submitLabel="Add account"
          initial={EMPTY_DETAILS}
          resetOnSuccess
          onSubmit={async (details) => {
            const account = await createAccount(organizationId, details);
            setCreated(account.name);
            await load();
          }}
        />
      )}
    </>
  );
}
