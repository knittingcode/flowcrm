import { type KeyboardEvent, useCallback, useEffect, useRef, useState } from 'react';
import { Link, useNavigate, useParams, useSearchParams } from 'react-router';
import type { Role } from '../../api/auth.ts';
import { ApiProblem } from '../../api/client.ts';
import { addMember, changeRole, removeMember, ROLES } from '../../api/memberships.ts';
import { getOrganization, listMembers, type Member, type MemberPage, type Organization } from '../../api/organizations.ts';
import { useAuth } from '../../auth/context.ts';
import { NotFoundPage } from '../../pages/NotFoundPage.tsx';
import { AddMemberForm, type Outcome } from './AddMemberForm.tsx';
import { failureMessage, needsReload } from './messages.ts';

type Load =
  | { kind: 'loading' }
  | { kind: 'ready'; organization: Organization; members: MemberPage; version: number }
  | { kind: 'not-found' }
  | { kind: 'forbidden' }
  | { kind: 'error'; message: string };

interface Feedback {
  kind: 'success' | 'error';
  message: string;
  /** Moves the focus to the message (when the control that was used may be gone). */
  focus: boolean;
}

function loadOf(error: unknown): Load {
  if (error instanceof ApiProblem && error.status === 404) {
    return { kind: 'not-found' };
  }
  if (error instanceof ApiProblem && error.status === 403) {
    return { kind: 'forbidden' };
  }
  if (error instanceof ApiProblem) {
    return { kind: 'error', message: `The members could not be loaded (request ${error.requestId ?? 'unknown'}).` };
  }
  return { kind: 'error', message: 'The API could not be reached.' };
}

/** The page from the address: a positive integer, otherwise the first page. */
function pageOf(value: string | null): number {
  return value !== null && /^[1-9][0-9]{0,5}$/.test(value) ? Number(value) : 1;
}

/**
 * The member administration of one organization. Controls are shown only
 * when the user's own membership in this organization has the permission;
 * the API decides every change. After every change, after every refusal
 * that may mean the list is stale (403 other than csrf-invalid, 404, 409),
 * and whenever it is unknown whether a change was saved (the API could not be
 * reached, or its success answer could not be read), the organization and
 * the members are read again: nothing is changed in the page before the
 * server has confirmed it.
 */
export function MembersPage() {
  const { organizationId = '' } = useParams();
  const [params, setParams] = useSearchParams();
  const page = pageOf(params.get('page'));
  const onPage = useCallback(
    (next: number) => {
      setParams(next === 1 ? {} : { page: String(next) });
    },
    [setParams],
  );

  return <MembersView key={organizationId} organizationId={organizationId} page={page} onPage={onPage} />;
}

function MembersView({ organizationId, page, onPage }: { organizationId: string; page: number; onPage: (page: number) => void }) {
  const { refresh } = useAuth();
  const navigate = useNavigate();
  const [load, setLoad] = useState<Load>({ kind: 'loading' });
  const [version, setVersion] = useState(0);
  const [pending, setPending] = useState(false);
  const [feedback, setFeedback] = useState<Feedback | null>(null);
  const [confirming, setConfirming] = useState<string | null>(null);
  /** The member whose Remove button gets the focus back once the confirmation is closed. */
  const restoreFocus = useRef<string | null>(null);
  const statusRef = useRef<HTMLDivElement>(null);
  const alertRef = useRef<HTMLDivElement>(null);
  const removeButtons = useRef(new Map<string, HTMLButtonElement>());

  useEffect(() => {
    const controller = new AbortController();
    Promise.all([getOrganization(organizationId, controller.signal), listMembers(organizationId, page, controller.signal)]).then(
      ([organization, members]) => {
        if (!controller.signal.aborted) {
          setLoad({ kind: 'ready', organization, members, version });
        }
      },
      (error: unknown) => {
        if (!controller.signal.aborted) {
          setLoad(loadOf(error));
        }
      },
    );
    return () => {
      controller.abort();
    };
  }, [organizationId, page, version]);

  useEffect(() => {
    if (feedback?.focus === true) {
      (feedback.kind === 'error' ? alertRef : statusRef).current?.focus();
    }
  }, [feedback]);

  useEffect(() => {
    if (confirming === null && restoreFocus.current !== null) {
      removeButtons.current.get(restoreFocus.current)?.focus();
      restoreFocus.current = null;
    }
  }, [confirming]);

  const reload = useCallback(() => {
    setVersion((v) => v + 1);
  }, []);

  /** Runs one change; reports the answer and reads the list again. */
  const run = useCallback(
    async (
      action: () => Promise<unknown>,
      success: string,
      options: { fields?: boolean; leave?: boolean; refreshSession?: boolean; focus?: boolean } = {},
    ): Promise<Outcome> => {
      setPending(true);
      setFeedback(null);
      try {
        await action();
      } catch (error: unknown) {
        setPending(false);
        if (error instanceof ApiProblem && error.status === 401) {
          // The AuthProvider has ended the session; the login follows.
          return { status: 'failed' };
        }
        if (error instanceof ApiProblem && error.status === 422 && options.fields === true) {
          return { status: 'invalid', errors: error.errors };
        }
        setFeedback({ kind: 'error', message: failureMessage(error), focus: true });
        if (needsReload(error)) {
          reload();
        }
        return { status: 'failed' };
      }
      if (options.leave === true) {
        await refresh();
        await navigate('/', { replace: true });
        return { status: 'done' };
      }
      setPending(false);
      if (options.refreshSession === true) {
        void refresh();
      }
      setFeedback({ kind: 'success', message: success, focus: options.focus ?? true });
      reload();
      return { status: 'done' };
    },
    [navigate, refresh, reload],
  );

  if (load.kind === 'loading') {
    return <p role="status">Loading the members…</p>;
  }
  if (load.kind === 'not-found') {
    return <NotFoundPage />;
  }
  if (load.kind === 'forbidden') {
    return <p role="alert">You do not have permission to see this.</p>;
  }
  if (load.kind === 'error') {
    return <p role="alert">{load.message}</p>;
  }

  const { organization, members } = load;
  const permissions = organization.membership.permissions;
  const withEmail = permissions.includes('membership.view_email');
  const canAdd = permissions.includes('membership.add');
  const canChange = permissions.includes('membership.change_role');
  const canRemove = permissions.includes('membership.remove');
  const pages = Math.max(1, Math.ceil(members.meta.total / members.meta.pageSize));
  const ownId = organization.membership.id;

  return (
    <>
      <h1>Members of {organization.name}</h1>
      <p>
        <Link to={`/o/${encodeURIComponent(organization.id)}`}>Back to {organization.name}</Link>
      </p>
      {/* Always present, so that screen readers announce what is put into it. */}
      <div role="status" tabIndex={-1} ref={statusRef}>
        {feedback?.kind === 'success' ? feedback.message : ''}
      </div>
      {feedback?.kind === 'error' && (
        <div className="form-error" role="alert" tabIndex={-1} ref={alertRef}>
          {feedback.message}
        </div>
      )}
      {canAdd && (
        <AddMemberForm
          pending={pending}
          onAdd={(email, role) =>
            run(() => addMember(organization.id, { email, role }), `${email} was added as ${role}.`, { fields: true, focus: false })
          }
        />
      )}
      <section aria-labelledby="member-list-heading">
        <h2 id="member-list-heading">Members</h2>
        <table aria-busy={pending}>
          <caption>
            {members.meta.total} {members.meta.total === 1 ? 'member' : 'members'}
            {pages > 1 && `, page ${String(page)} of ${String(pages)}`}
          </caption>
          <thead>
            <tr>
              <th scope="col">Name</th>
              <th scope="col">Role</th>
              {withEmail && <th scope="col">E-mail address</th>}
              {(canChange || canRemove) && <th scope="col">Actions</th>}
            </tr>
          </thead>
          <tbody>
            {members.data.map((member) => (
              <MemberRow
                // Every answer of the server starts the rows afresh: the selects show the roles it has.
                key={`${member.membershipId}:${String(load.version)}`}
                member={member}
                organizationName={organization.name}
                self={member.membershipId === ownId}
                withEmail={withEmail}
                canChange={canChange}
                canRemove={canRemove}
                pending={pending}
                confirming={confirming === member.membershipId}
                registerRemoveButton={(button) => {
                  if (button === null) {
                    removeButtons.current.delete(member.membershipId);
                  } else {
                    removeButtons.current.set(member.membershipId, button);
                  }
                }}
                onChangeRole={(role) => {
                  void run(
                    () => changeRole(organization.id, member.membershipId, role),
                    `The role of ${member.displayName} is now ${role}.`,
                    { refreshSession: member.membershipId === ownId },
                  );
                }}
                onConfirm={() => {
                  setConfirming(member.membershipId);
                }}
                onCancel={() => {
                  restoreFocus.current = member.membershipId;
                  setConfirming(null);
                }}
                onRemove={() => {
                  setConfirming(null);
                  void run(() => removeMember(organization.id, member.membershipId), `${member.displayName} was removed.`, {
                    leave: member.membershipId === ownId,
                  });
                }}
              />
            ))}
          </tbody>
        </table>
        {members.data.length === 0 && page > 1 && (
          <p>
            This page has no members.{' '}
            <button
              type="button"
              onClick={() => {
                onPage(1);
              }}
            >
              Go to the first page
            </button>
          </p>
        )}
        {pages > 1 && (
          <nav aria-label="Member pages" className="pager">
            <button
              type="button"
              disabled={page <= 1}
              onClick={() => {
                onPage(page - 1);
              }}
            >
              Previous
            </button>
            <span>
              Page {page} of {pages}
            </span>
            <button
              type="button"
              disabled={page >= pages}
              onClick={() => {
                onPage(page + 1);
              }}
            >
              Next
            </button>
          </nav>
        )}
      </section>
    </>
  );
}

interface RowProps {
  member: Member;
  organizationName: string;
  self: boolean;
  withEmail: boolean;
  canChange: boolean;
  canRemove: boolean;
  pending: boolean;
  confirming: boolean;
  registerRemoveButton: (button: HTMLButtonElement | null) => void;
  onChangeRole: (role: Role) => void;
  onConfirm: () => void;
  onCancel: () => void;
  onRemove: () => void;
}

function MemberRow({
  member,
  organizationName,
  self,
  withEmail,
  canChange,
  canRemove,
  pending,
  confirming,
  registerRemoveButton,
  onChangeRole,
  onConfirm,
  onCancel,
  onRemove,
}: RowProps) {
  const [role, setRole] = useState<Role>(member.role);
  const id = `member-${member.membershipId}`;
  const selfWarning = self && role !== member.role;

  return (
    <tr>
      <th scope="row">
        {member.displayName}
        {self && ' (you)'}
      </th>
      <td>{member.role}</td>
      {withEmail && <td>{member.email}</td>}
      {(canChange || canRemove) && (
        <td>
          <div className="member-actions">
          {canChange && (
            <div className="change-role">
              <label className="visually-hidden" htmlFor={`${id}-role`}>
                New role for {member.displayName}
              </label>
              <select
                id={`${id}-role`}
                value={role}
                onChange={(event) => {
                  setRole(event.target.value as Role);
                }}
              >
                {ROLES.map((r) => (
                  <option key={r} value={r}>
                    {r}
                  </option>
                ))}
              </select>
              <button
                type="button"
                aria-label={`Change role of ${member.displayName}`}
                disabled={pending || role === member.role}
                {...(selfWarning ? { 'aria-describedby': `${id}-self-role` } : {})}
                onClick={() => {
                  onChangeRole(role);
                }}
              >
                Change role
              </button>
              {selfWarning && (
                <p id={`${id}-self-role`} className="warning">
                  This is your own membership. With another role you may no longer be able to manage members.
                </p>
              )}
            </div>
          )}
          {canRemove && !confirming && (
            <button
              type="button"
              ref={registerRemoveButton}
              aria-label={`Remove ${member.displayName}`}
              disabled={pending}
              onClick={onConfirm}
            >
              Remove
            </button>
          )}
          {canRemove && confirming && (
            <ConfirmRemoval
              id={id}
              member={member}
              organizationName={organizationName}
              self={self}
              pending={pending}
              onCancel={onCancel}
              onRemove={onRemove}
            />
          )}
          </div>
        </td>
      )}
    </tr>
  );
}

function ConfirmRemoval(props: {
  id: string;
  member: Member;
  organizationName: string;
  self: boolean;
  pending: boolean;
  onCancel: () => void;
  onRemove: () => void;
}) {
  const cancelRef = useRef<HTMLButtonElement>(null);

  useEffect(() => {
    cancelRef.current?.focus();
  }, []);

  function keyDown(event: KeyboardEvent<HTMLDivElement>) {
    if (event.key === 'Escape') {
      event.preventDefault();
      props.onCancel();
    }
  }

  return (
    <div className="confirm" role="group" aria-labelledby={`${props.id}-confirm`} onKeyDown={keyDown}>
      <p id={`${props.id}-confirm`}>
        Remove {props.member.displayName} from {props.organizationName}?
      </p>
      {props.self && (
        <p className="warning">You are removing yourself: you will lose access to this organization immediately.</p>
      )}
      <button type="button" aria-label={`Yes, remove ${props.member.displayName}`} disabled={props.pending} onClick={props.onRemove}>
        Yes, remove
      </button>
      <button type="button" ref={cancelRef} onClick={props.onCancel}>
        Cancel
      </button>
    </div>
  );
}
