import type { ReactNode } from 'react';
import { Navigate, useLocation } from 'react-router';
import { useAuth } from './context.ts';
import { loginPath } from './returnTo.ts';

/**
 * Shows its children only to a logged-in user; anyone else goes to the
 * login page, which leads back here afterwards. This only decides what the
 * SPA shows: the API authorizes every request itself.
 */
export function RequireAuth({ children }: { children: ReactNode }) {
  const { state, refresh } = useAuth();
  const location = useLocation();

  if (state.status === 'loading') {
    return (
      <p className="shell-main" role="status">
        Loading…
      </p>
    );
  }
  if (state.status === 'unavailable') {
    return (
      <div className="shell-main" role="alert">
        <p>The API could not be reached.</p>
        <button type="button" onClick={() => void refresh()}>
          Retry
        </button>
      </div>
    );
  }
  if (state.status === 'anonymous') {
    return <Navigate to={loginPath(location.pathname + location.search)} replace state={{ ended: state.ended }} />;
  }
  return children;
}
