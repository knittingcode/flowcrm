import { type SyntheticEvent, useEffect, useRef, useState } from 'react';
import type { Role } from '../../api/auth.ts';
import type { ProblemDetail } from '../../api/client.ts';
import { ROLES } from '../../api/memberships.ts';
import { fieldMessage } from './messages.ts';

/** What became of a submitted change: done, refused with field errors, or failed (reported by the page). */
export type Outcome = { status: 'done' } | { status: 'invalid'; errors: readonly ProblemDetail[] } | { status: 'failed' };

interface Invalid {
  email?: string;
  role?: string;
  summary: string[];
}

function invalidOf(errors: readonly ProblemDetail[]): Invalid {
  const invalid: Invalid = { summary: [] };
  for (const detail of errors) {
    const message = fieldMessage(detail);
    invalid.summary.push(message);
    if (detail.pointer === '/email') {
      invalid.email ??= message;
    } else if (detail.pointer === '/role') {
      invalid.role ??= message;
    }
  }
  return invalid;
}

/**
 * Adds an existing user by e-mail address. Field errors of a 422 answer are
 * shown at their inputs (aria-describedby) and in a summary; the first
 * invalid input receives the focus.
 */
export function AddMemberForm({ pending, onAdd }: { pending: boolean; onAdd: (email: string, role: Role) => Promise<Outcome> }) {
  const [email, setEmail] = useState('');
  const [role, setRole] = useState<Role>('REP');
  const [invalid, setInvalid] = useState<Invalid | null>(null);
  const emailRef = useRef<HTMLInputElement>(null);
  const roleRef = useRef<HTMLSelectElement>(null);
  const summaryRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (invalid === null) {
      return;
    }
    if (invalid.email !== undefined) {
      emailRef.current?.focus();
    } else if (invalid.role !== undefined) {
      roleRef.current?.focus();
    } else {
      summaryRef.current?.focus();
    }
  }, [invalid]);

  async function submit(event: SyntheticEvent<HTMLFormElement>) {
    event.preventDefault();
    setInvalid(null);
    const outcome = await onAdd(email.trim(), role);
    if (outcome.status === 'invalid') {
      setInvalid(invalidOf(outcome.errors));
    } else if (outcome.status === 'done') {
      setEmail('');
      setRole('REP');
      emailRef.current?.focus();
    }
  }

  return (
    <form className="add-member" aria-labelledby="add-member-heading" aria-busy={pending} noValidate onSubmit={(event) => void submit(event)}>
      <h2 id="add-member-heading">Add a member</h2>
      {invalid !== null && (
        <div className="form-error" role="alert" tabIndex={-1} ref={summaryRef} aria-labelledby="add-member-errors">
          <p id="add-member-errors">The member could not be added:</p>
          <ul>
            {invalid.summary.map((message, index) => (
              <li key={String(index)}>{message}</li>
            ))}
          </ul>
        </div>
      )}
      <label htmlFor="add-member-email">E-mail address of the user</label>
      <input
        id="add-member-email"
        ref={emailRef}
        type="email"
        autoComplete="off"
        required
        value={email}
        aria-invalid={invalid?.email !== undefined}
        {...(invalid?.email === undefined ? {} : { 'aria-describedby': 'add-member-email-error' })}
        onChange={(event) => {
          setEmail(event.target.value);
        }}
      />
      {invalid?.email !== undefined && (
        <p id="add-member-email-error" className="field-error">
          {invalid.email}
        </p>
      )}
      <label htmlFor="add-member-role">Role</label>
      <select
        id="add-member-role"
        ref={roleRef}
        value={role}
        aria-invalid={invalid?.role !== undefined}
        {...(invalid?.role === undefined ? {} : { 'aria-describedby': 'add-member-role-error' })}
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
      {invalid?.role !== undefined && (
        <p id="add-member-role-error" className="field-error">
          {invalid.role}
        </p>
      )}
      <button type="submit" disabled={pending}>
        {pending ? 'Adding…' : 'Add member'}
      </button>
    </form>
  );
}
