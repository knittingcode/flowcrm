import { apiRequest, unexpected } from './client.ts';

/** A customer company of an organization. */
export interface Account {
  id: string;
  name: string;
  website: string | null;
  email: string | null;
  phone: string | null;
  createdAt: string;
  updatedAt: string;
  archivedAt: string | null;
}

/** What a user can enter; an empty optional value means none. */
export interface AccountDetails {
  name: string;
  website: string;
  email: string;
  phone: string;
}

export const EMPTY_DETAILS: AccountDetails = { name: '', website: '', email: '', phone: '' };

export interface AccountPage {
  data: Account[];
  meta: { page: number; pageSize: number; total: number };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null;
}

function isOptionalText(value: unknown): value is string | null {
  return value === null || typeof value === 'string';
}

function readAccount(body: unknown): Account {
  if (
    isRecord(body) &&
    typeof body.id === 'string' &&
    typeof body.name === 'string' &&
    isOptionalText(body.website) &&
    isOptionalText(body.email) &&
    isOptionalText(body.phone) &&
    typeof body.createdAt === 'string' &&
    typeof body.updatedAt === 'string' &&
    isOptionalText(body.archivedAt)
  ) {
    return {
      id: body.id,
      name: body.name,
      website: body.website,
      email: body.email,
      phone: body.phone,
      createdAt: body.createdAt,
      updatedAt: body.updatedAt,
      archivedAt: body.archivedAt,
    };
  }
  return unexpected();
}

function readAccountPage(body: unknown): AccountPage {
  if (
    isRecord(body) &&
    Array.isArray(body.data) &&
    isRecord(body.meta) &&
    typeof body.meta.page === 'number' &&
    typeof body.meta.pageSize === 'number' &&
    typeof body.meta.total === 'number'
  ) {
    return { data: body.data.map(readAccount), meta: { page: body.meta.page, pageSize: body.meta.pageSize, total: body.meta.total } };
  }
  return unexpected();
}

function base(organizationId: string): string {
  return `/api/v1/organizations/${encodeURIComponent(organizationId)}/accounts`;
}

/** The body of a create or update request: empty optional values are sent as null. */
function bodyOf(details: AccountDetails): Record<string, string | null> {
  const optional = (value: string): string | null => (value.trim() === '' ? null : value);
  return { name: details.name, website: optional(details.website), email: optional(details.email), phone: optional(details.phone) };
}

export function listAccounts(organizationId: string, page: number, signal?: AbortSignal): Promise<AccountPage> {
  return apiRequest(`${base(organizationId)}?page=${String(page)}`, signal === undefined ? {} : { signal }, readAccountPage);
}

export function getAccount(organizationId: string, accountId: string, signal?: AbortSignal): Promise<Account> {
  return apiRequest(`${base(organizationId)}/${encodeURIComponent(accountId)}`, signal === undefined ? {} : { signal }, readAccount);
}

export function createAccount(organizationId: string, details: AccountDetails): Promise<Account> {
  return apiRequest(base(organizationId), { method: 'POST', body: bodyOf(details) }, readAccount);
}

export function updateAccount(organizationId: string, accountId: string, details: AccountDetails): Promise<Account> {
  return apiRequest(`${base(organizationId)}/${encodeURIComponent(accountId)}`, { method: 'PUT', body: bodyOf(details) }, readAccount);
}

export function archiveAccount(organizationId: string, accountId: string): Promise<null> {
  return apiRequest(`${base(organizationId)}/${encodeURIComponent(accountId)}/archive`, { method: 'POST' }, () => null);
}
