import { type SyntheticEvent, useEffect, useRef, useState } from 'react';
import { Navigate, useLocation, useNavigate, useSearchParams } from 'react-router';
import { ApiProblem } from '../api/client.ts';
import { useAuth } from '../auth/context.ts';
import { safeReturnTo } from '../auth/returnTo.ts';
import { SystemStatusPanel } from '../features/system-status/SystemStatusPanel.tsx';

/** One message per kind of failure; a failed login never says which part was wrong. */
function describe(error: unknown): string {
  if (error instanceof ApiProblem) {
    if (error.status === 401) {
      return 'The e-mail address or the password is wrong.';
    }
    if (error.status === 429) {
      const minutes = Math.max(1, Math.ceil((error.retryAfterSeconds ?? 60) / 60));
      return `Too many failed attempts. Try again in ${String(minutes)} ${minutes === 1 ? 'minute' : 'minutes'}.`;
    }
    return `Signing in is not possible right now (request ${error.requestId ?? 'unknown'}).`;
  }
  return 'The API could not be reached.';
}

function sessionEnded(state: unknown): boolean {
  return typeof state === 'object' && state !== null && 'ended' in state && state.ended === true;
}

export function LoginPage() {
  const { state, login } = useAuth();
  const [params] = useSearchParams();
  const location = useLocation();
  const navigate = useNavigate();
  const returnTo = safeReturnTo(params.get('returnTo'));
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const errorRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (error !== null) {
      errorRef.current?.focus();
    }
  }, [error]);

  if (state.status === 'authenticated' && !pending) {
    return <Navigate to={returnTo} replace />;
  }

  async function submit(event: SyntheticEvent<HTMLFormElement>) {
    event.preventDefault();
    setPending(true);
    setError(null);
    try {
      await login(email, password);
      await navigate(returnTo, { replace: true });
    } catch (failure: unknown) {
      setPassword('');
      setError(describe(failure));
    } finally {
      setPending(false);
    }
  }

  return (
    <div className="shell">
      <header className="shell-header">
        <span className="brand">FlowCRM</span>
      </header>
      <main className="shell-main login">
        <h1>Sign in</h1>
        {sessionEnded(location.state) && error === null && <p role="status">Your session has ended. Please sign in again.</p>}
        {error !== null && (
          <div className="form-error" role="alert" tabIndex={-1} ref={errorRef}>
            {error}
          </div>
        )}
        <form onSubmit={(event) => void submit(event)} aria-busy={pending}>
          <label htmlFor="login-email">E-mail address</label>
          <input
            id="login-email"
            type="email"
            autoComplete="username"
            required
            value={email}
            onChange={(event) => {
              setEmail(event.target.value);
            }}
          />
          <label htmlFor="login-password">Password</label>
          <input
            id="login-password"
            type="password"
            autoComplete="current-password"
            required
            value={password}
            onChange={(event) => {
              setPassword(event.target.value);
            }}
          />
          <button type="submit" disabled={pending}>
            {pending ? 'Signing in…' : 'Sign in'}
          </button>
        </form>
        <SystemStatusPanel />
      </main>
    </div>
  );
}
