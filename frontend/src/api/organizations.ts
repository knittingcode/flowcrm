import type { Permission, Role } from './auth.ts';
import { apiRequest, unexpected } from './client.ts';

export interface Organization {
  id: string;
  name: string;
  currency: string;
  timezone: string;
  membership: { id: string; role: Role; permissions: Permission[] };
}

export interface Member {
  membershipId: string;
  userId: string;
  displayName: string;
  role: Role;
  /** Only with the permission membership.view_email. */
  email?: string;
}

export interface MemberPage {
  data: Member[];
  meta: { page: number; pageSize: number; total: number };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null;
}

function isRole(value: unknown): value is Role {
  return value === 'ADMIN' || value === 'MANAGER' || value === 'REP';
}

function readOrganization(body: unknown): Organization {
  if (
    isRecord(body) &&
    typeof body.id === 'string' &&
    typeof body.name === 'string' &&
    typeof body.currency === 'string' &&
    typeof body.timezone === 'string' &&
    isRecord(body.membership) &&
    typeof body.membership.id === 'string' &&
    isRole(body.membership.role) &&
    Array.isArray(body.membership.permissions)
  ) {
    return {
      id: body.id,
      name: body.name,
      currency: body.currency,
      timezone: body.timezone,
      membership: {
        id: body.membership.id,
        role: body.membership.role,
        permissions: body.membership.permissions.filter((p): p is Permission => typeof p === 'string'),
      },
    };
  }
  return unexpected();
}

function readMember(value: unknown): Member {
  if (
    isRecord(value) &&
    typeof value.membershipId === 'string' &&
    typeof value.userId === 'string' &&
    typeof value.displayName === 'string' &&
    isRole(value.role)
  ) {
    const member: Member = { membershipId: value.membershipId, userId: value.userId, displayName: value.displayName, role: value.role };
    if (typeof value.email === 'string') {
      member.email = value.email;
    }
    return member;
  }
  return unexpected();
}

function readMemberPage(body: unknown): MemberPage {
  if (
    isRecord(body) &&
    Array.isArray(body.data) &&
    isRecord(body.meta) &&
    typeof body.meta.page === 'number' &&
    typeof body.meta.pageSize === 'number' &&
    typeof body.meta.total === 'number'
  ) {
    return { data: body.data.map(readMember), meta: { page: body.meta.page, pageSize: body.meta.pageSize, total: body.meta.total } };
  }
  return unexpected();
}

export function getOrganization(organizationId: string, signal?: AbortSignal): Promise<Organization> {
  return apiRequest(
    `/api/v1/organizations/${encodeURIComponent(organizationId)}`,
    signal === undefined ? {} : { signal },
    readOrganization,
  );
}

export function listMembers(organizationId: string, page: number, signal?: AbortSignal): Promise<MemberPage> {
  return apiRequest(
    `/api/v1/organizations/${encodeURIComponent(organizationId)}/members?page=${String(page)}`,
    signal === undefined ? {} : { signal },
    readMemberPage,
  );
}
