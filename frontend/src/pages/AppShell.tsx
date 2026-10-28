import { useState } from 'react';
import { NavLink, Outlet, useNavigate } from 'react-router';
import { useAuth } from '../auth/context.ts';

/** The layout of the logged-in application: user, organization switcher and logout. */
export function AppShell() {
  const { state, logout } = useAuth();
  const navigate = useNavigate();
  const [pending, setPending] = useState(false);
  const [failed, setFailed] = useState(false);
  if (state.status !== 'authenticated') {
    return null;
  }
  const { user, memberships } = state.session;

  /** Goes to the login only when the session has ended; otherwise says that it may not have. */
  async function signOut() {
    setPending(true);
    setFailed(false);
    try {
      await logout();
    } catch {
      setPending(false);
      setFailed(true);
      return;
    }
    setPending(false);
    await navigate('/login', { replace: true });
  }

  return (
    <div className="shell">
      <header className="shell-header">
        <span className="brand">FlowCRM</span>
        {memberships.length > 0 && (
          <nav aria-label="Organizations">
            <ul className="organization-switcher">
              {memberships.map((membership) => (
                <li key={membership.organizationId}>
                  <NavLink to={`/o/${membership.organizationId}`}>{membership.organizationName}</NavLink>
                </li>
              ))}
            </ul>
          </nav>
        )}
        <span className="user">{user.displayName}</span>
        <button type="button" onClick={() => void signOut()} disabled={pending}>
          Sign out
        </button>
      </header>
      {failed && (
        <p role="alert" className="form-error shell-alert">
          Signing out did not complete. You may still be signed in, so try again.
        </p>
      )}
      <main className="shell-main">
        <Outlet />
      </main>
    </div>
  );
}
