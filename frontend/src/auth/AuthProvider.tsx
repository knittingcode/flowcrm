import { type ReactNode, useCallback, useEffect, useMemo, useState } from 'react';
import { getSession, login as apiLogin, logout as apiLogout, type Session } from '../api/auth.ts';
import { onUnauthenticated, setCsrfRefresher, setCsrfToken } from '../api/client.ts';
import { type Auth, AuthContext, type AuthState } from './context.ts';

/**
 * The authentication state of the SPA (ADR-019): read from
 * GET /api/v1/auth/session on load, set by login and logout, and reset to
 * anonymous whenever the API answers 401 (the server ended the session).
 * The CSRF token is kept in memory only. Nothing is written to browser
 * storage.
 */
export function AuthProvider({ children }: { children: ReactNode }) {
  const [state, setState] = useState<AuthState>({ status: 'loading' });

  const apply = useCallback((session: Session) => {
    if (session.authenticated) {
      setCsrfToken(session.csrfToken);
      setState({ status: 'authenticated', session });
    } else {
      setCsrfToken(null);
      setState({ status: 'anonymous', ended: false });
    }
  }, []);

  const refresh = useCallback(async () => {
    try {
      apply(await getSession());
    } catch {
      setState({ status: 'unavailable' });
    }
  }, [apply]);

  useEffect(() => {
    const controller = new AbortController();
    getSession(controller.signal).then(apply, () => {
      if (!controller.signal.aborted) {
        setState({ status: 'unavailable' });
      }
    });
    onUnauthenticated(() => {
      setCsrfToken(null);
      setState({ status: 'anonymous', ended: true });
    });
    setCsrfRefresher(async () => {
      apply(await getSession());
    });
    return () => {
      controller.abort();
      onUnauthenticated(null);
      setCsrfRefresher(null);
    };
  }, [apply]);

  const login = useCallback(
    async (email: string, password: string) => {
      apply(await apiLogin(email, password));
    },
    [apply],
  );

  const logout = useCallback(async () => {
    try {
      await apiLogout();
    } finally {
      setCsrfToken(null);
      setState({ status: 'anonymous', ended: false });
    }
  }, []);

  const auth = useMemo<Auth>(() => ({ state, login, logout, refresh }), [state, login, logout, refresh]);

  return <AuthContext value={auth}>{children}</AuthContext>;
}
