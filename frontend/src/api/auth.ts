import { apiRequest, unexpected } from './client.ts';

export type Role = 'ADMIN' | 'MANAGER' | 'REP';
export type Permission =
  | 'organization.view'
  | 'membership.list'
  | 'membership.view_email'
  | 'membership.add'
  | 'membership.change_role'
  | 'membership.remove';

export interface User {
  id: string;
  email: string;
  displayName: string;
}

/** An active membership, with what its role may do (for showing controls only; the server decides). */
export interface Membership {
  organizationId: string;
  organizationName: string;
  membershipId: string;
  role: Role;
  permissions: Permission[];
}

export interface AuthenticatedSession {
  authenticated: true;
  user: User;
  memberships: Membership[];
  csrfToken: string;
  expiresAt: string;
}

export type Session = { authenticated: false } | AuthenticatedSession;

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null;
}

function isUser(value: unknown): value is User {
  return isRecord(value) && typeof value.id === 'string' && typeof value.email === 'string' && typeof value.displayName === 'string';
}

function isMembership(value: unknown): value is Membership {
  return (
    isRecord(value) &&
    typeof value.organizationId === 'string' &&
    typeof value.organizationName === 'string' &&
    typeof value.membershipId === 'string' &&
    (value.role === 'ADMIN' || value.role === 'MANAGER' || value.role === 'REP') &&
    Array.isArray(value.permissions) &&
    value.permissions.every((p) => typeof p === 'string')
  );
}

export function readSession(body: unknown): Session {
  if (isRecord(body) && body.authenticated === false) {
    return { authenticated: false };
  }
  if (
    isRecord(body) &&
    body.authenticated === true &&
    isUser(body.user) &&
    Array.isArray(body.memberships) &&
    body.memberships.every(isMembership) &&
    typeof body.csrfToken === 'string' &&
    typeof body.expiresAt === 'string'
  ) {
    return {
      authenticated: true,
      user: body.user,
      memberships: body.memberships,
      csrfToken: body.csrfToken,
      expiresAt: body.expiresAt,
    };
  }
  return unexpected();
}

export function getSession(signal?: AbortSignal): Promise<Session> {
  return apiRequest('/api/v1/auth/session', signal === undefined ? {} : { signal }, readSession);
}

export async function login(email: string, password: string): Promise<AuthenticatedSession> {
  const session = await apiRequest(
    '/api/v1/auth/login',
    { method: 'POST', body: { email, password }, authenticating: true },
    readSession,
  );
  return session.authenticated ? session : unexpected();
}

export function logout(): Promise<null> {
  return apiRequest('/api/v1/auth/logout', { method: 'POST' }, () => null);
}
