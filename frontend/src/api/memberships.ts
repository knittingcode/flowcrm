import type { Role } from './auth.ts';
import { ApiProblem, apiRequest } from './client.ts';
import { type Member, readMember } from './organizations.ts';

/** The roles in the order the forms offer them. */
export const ROLES: readonly Role[] = ['ADMIN', 'MANAGER', 'REP'];

/** Codes of a 409 /problems/conflict answer to a membership change. */
export type ConflictCode = 'LAST_ADMIN' | 'MEMBERSHIP_EXISTS';

function membersPath(organizationId: string): string {
  return `/api/v1/organizations/${encodeURIComponent(organizationId)}/members`;
}

function memberPath(organizationId: string, membershipId: string): string {
  return `${membersPath(organizationId)}/${encodeURIComponent(membershipId)}`;
}

/** Adds an existing user to the organization (permission membership.add); 201 with the new member. */
export function addMember(organizationId: string, member: { email: string; role: Role }): Promise<Member> {
  return apiRequest(membersPath(organizationId), { method: 'POST', body: { email: member.email, role: member.role } }, readMember);
}

/** Changes the role of an active member (permission membership.change_role). */
export function changeRole(organizationId: string, membershipId: string, role: Role): Promise<Member> {
  return apiRequest(memberPath(organizationId, membershipId), { method: 'PATCH', body: { role } }, readMember);
}

/** Removes a member (permission membership.remove); 204. The membership is deactivated by the server. */
export function removeMember(organizationId: string, membershipId: string): Promise<null> {
  return apiRequest(memberPath(organizationId, membershipId), { method: 'DELETE' }, () => null);
}

/** Whether `error` is a 409 conflict with this code. */
export function isConflict(error: unknown, code: ConflictCode): boolean {
  return error instanceof ApiProblem && error.status === 409 && error.type === '/problems/conflict' && error.errors.some((e) => e.code === code);
}
