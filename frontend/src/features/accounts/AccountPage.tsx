import { useEffect, useState } from 'react';
import { Link, useParams } from 'react-router';
import { type Account, archiveAccount, getAccount, updateAccount } from '../../api/accounts.ts';
import { ApiProblem } from '../../api/client.ts';
import { useAuth } from '../../auth/context.ts';
import { NotFoundPage } from '../../pages/NotFoundPage.tsx';
import { AccountForm } from './AccountForm.tsx';

type State =
  | { kind: 'loading' }
  | { kind: 'ready'; account: Account }
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
    return { kind: 'error', message: `The account could not be loaded (request ${error.requestId ?? 'unknown'}).` };
  }
  return { kind: 'error', message: 'The API could not be reached.' };
}

function date(instant: string): string {
  return new Date(instant).toLocaleString();
}

/**
 * One account: its details, a form to change them and archiving, each for
 * members with the permission. An account of another organization is the
 * same "not found" as an unknown one.
 */
export function AccountPage() {
  const { organizationId = '', accountId = '' } = useParams();

  return <AccountView key={`${organizationId}:${accountId}`} organizationId={organizationId} accountId={accountId} />;
}

function AccountView({ organizationId, accountId }: { organizationId: string; accountId: string }) {
  const { state: auth } = useAuth();
  const [state, setState] = useState<State>({ kind: 'loading' });
  const [saved, setSaved] = useState(false);
  const [confirming, setConfirming] = useState(false);
  const [archiveError, setArchiveError] = useState<string | null>(null);

  useEffect(() => {
    const controller = new AbortController();
    getAccount(organizationId, accountId, controller.signal).then(
      (account) => {
        setState({ kind: 'ready', account });
      },
      (error: unknown) => {
        if (!controller.signal.aborted) {
          setState(stateOf(error));
        }
      },
    );
    return () => {
      controller.abort();
    };
  }, [organizationId, accountId]);

  if (state.kind === 'loading') {
    return <p role="status">Loading the account…</p>;
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

  const { account } = state;
  const archived = account.archivedAt !== null;
  const membership = auth.status === 'authenticated' ? auth.session.memberships.find((m) => m.organizationId === organizationId) : undefined;
  const mayManage = membership?.permissions.includes('account.manage') === true;
  const mayArchive = membership?.permissions.includes('account.archive') === true;

  async function archive() {
    setArchiveError(null);
    try {
      await archiveAccount(organizationId, accountId);
      setState({ kind: 'ready', account: await getAccount(organizationId, accountId) });
      setConfirming(false);
      setSaved(false);
    } catch (failure: unknown) {
      setArchiveError(
        failure instanceof ApiProblem && failure.status === 403
          ? 'You do not have permission to archive accounts.'
          : failure instanceof ApiProblem
            ? `The account could not be archived (request ${failure.requestId ?? 'unknown'}).`
            : 'The API could not be reached.',
      );
    }
  }

  return (
    <>
      <p>
        <Link to={`/o/${organizationId}/accounts`}>All accounts</Link>
      </p>
      <h1>{account.name}</h1>
      {archived && <p role="status">This account is archived. It is no longer in the list and cannot be changed.</p>}
      <dl className="facts">
        <dt>Website</dt>
        <dd>{account.website === null ? '—' : <a href={account.website} rel="noreferrer noopener">{account.website}</a>}</dd>
        <dt>E-mail address</dt>
        <dd>{account.email ?? '—'}</dd>
        <dt>Phone</dt>
        <dd>{account.phone ?? '—'}</dd>
        <dt>Created</dt>
        <dd>{date(account.createdAt)}</dd>
        <dt>Last changed</dt>
        <dd>{date(account.updatedAt)}</dd>
      </dl>
      {saved && <p role="status">The changes were saved.</p>}
      {mayManage && !archived && (
        <AccountForm
          key={account.updatedAt}
          legend="Edit account"
          submitLabel="Save changes"
          initial={{ name: account.name, website: account.website ?? '', email: account.email ?? '', phone: account.phone ?? '' }}
          resetOnSuccess={false}
          onSubmit={async (details) => {
            setSaved(false);
            const updated = await updateAccount(organizationId, accountId, details);
            setState({ kind: 'ready', account: updated });
            setSaved(true);
          }}
        />
      )}
      {mayArchive && !archived && (
        <section aria-labelledby="archive-heading" className="danger">
          <h2 id="archive-heading">Archive</h2>
          <p>An archived account leaves the list and can no longer be changed. Its data is kept.</p>
          {archiveError !== null && (
            <p className="form-error" role="alert">
              {archiveError}
            </p>
          )}
          {confirming ? (
            <p className="pager">
              <button type="button" onClick={() => void archive()}>
                Archive this account
              </button>
              <button type="button" onClick={() => { setConfirming(false); }}>
                Cancel
              </button>
            </p>
          ) : (
            <button type="button" onClick={() => { setConfirming(true); }}>
              Archive…
            </button>
          )}
        </section>
      )}
    </>
  );
}
