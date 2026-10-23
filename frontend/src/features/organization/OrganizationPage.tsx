import { useEffect, useState } from 'react';
import { useParams } from 'react-router';
import { ApiProblem } from '../../api/client.ts';
import { getOrganization, listMembers, type MemberPage, type Organization } from '../../api/organizations.ts';
import { NotFoundPage } from '../../pages/NotFoundPage.tsx';

type State =
  | { kind: 'loading' }
  | { kind: 'ready'; organization: Organization; members: MemberPage }
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
    return { kind: 'error', message: `The organization could not be loaded (request ${error.requestId ?? 'unknown'}).` };
  }
  return { kind: 'error', message: 'The API could not be reached.' };
}

/**
 * One organization: the profile and the member directory. The organization
 * comes from the address; the API decides whether the user may see it (a
 * foreign or unknown one is the same "not found").
 */
export function OrganizationPage() {
  const { organizationId = '' } = useParams();
  const [page, setPage] = useState(1);

  // A new organization or page is a new view that starts loading.
  return <OrganizationView key={`${organizationId}:${String(page)}`} organizationId={organizationId} page={page} onPage={setPage} />;
}

function OrganizationView({ organizationId, page, onPage }: { organizationId: string; page: number; onPage: (page: number) => void }) {
  const [state, setState] = useState<State>({ kind: 'loading' });

  useEffect(() => {
    const controller = new AbortController();
    Promise.all([getOrganization(organizationId, controller.signal), listMembers(organizationId, page, controller.signal)]).then(
      ([organization, members]) => {
        setState({ kind: 'ready', organization, members });
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
  }, [organizationId, page]);

  if (state.kind === 'loading') {
    return <p role="status">Loading the organization…</p>;
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

  const { organization, members } = state;
  const withEmail = organization.membership.permissions.includes('membership.view_email');
  const pages = Math.max(1, Math.ceil(members.meta.total / members.meta.pageSize));

  return (
    <>
      <h1>{organization.name}</h1>
      <dl className="facts">
        <dt>Your role</dt>
        <dd>{organization.membership.role}</dd>
        <dt>Currency</dt>
        <dd>{organization.currency}</dd>
        <dt>Time zone</dt>
        <dd>{organization.timezone}</dd>
      </dl>
      <section aria-labelledby="members-heading">
        <h2 id="members-heading">Members</h2>
        <table>
          <caption>
            {members.meta.total} {members.meta.total === 1 ? 'member' : 'members'}
          </caption>
          <thead>
            <tr>
              <th scope="col">Name</th>
              <th scope="col">Role</th>
              {withEmail && <th scope="col">E-mail address</th>}
            </tr>
          </thead>
          <tbody>
            {members.data.map((member) => (
              <tr key={member.membershipId}>
                <td>{member.displayName}</td>
                <td>{member.role}</td>
                {withEmail && <td>{member.email}</td>}
              </tr>
            ))}
          </tbody>
        </table>
        {pages > 1 && (
          <nav aria-label="Member pages" className="pager">
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
      </section>
    </>
  );
}
