import { createContext, useContext } from 'react';
import type { AuthenticatedSession } from '../api/auth.ts';

export type AuthState =
  | { status: 'loading' }
  | { status: 'unavailable' }
  | { status: 'anonymous'; ended: boolean }
  | { status: 'authenticated'; session: AuthenticatedSession };

export interface Auth {
  state: AuthState;
  login: (email: string, password: string) => Promise<void>;
  logout: () => Promise<void>;
  /** Reads the session again (for example after the API was unavailable). */
  refresh: () => Promise<void>;
}

export const AuthContext = createContext<Auth | null>(null);

export function useAuth(): Auth {
  const auth = useContext(AuthContext);
  if (auth === null) {
    throw new Error('useAuth() needs an AuthProvider.');
  }
  return auth;
}
