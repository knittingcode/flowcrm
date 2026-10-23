import { ApiProblem, type ProblemDetail } from '../../api/client.ts';
import { isConflict } from '../../api/memberships.ts';

/** Answers after which the list may no longer be what the server has: it is read again. */
export function needsReload(error: unknown): boolean {
  return error instanceof ApiProblem && (error.status === 403 || error.status === 404 || error.status === 409);
}

function waitTime(seconds: number | null): string {
  const value = seconds ?? 60;
  if (value < 60) {
    const s = Math.max(1, value);
    return `${String(s)} ${s === 1 ? 'second' : 'seconds'}`;
  }
  const minutes = Math.ceil(value / 60);
  return `${String(minutes)} ${minutes === 1 ? 'minute' : 'minutes'}`;
}

/** The message for one field error of a membership request. */
export function fieldMessage(detail: ProblemDetail): string {
  if (detail.pointer === '/email') {
    if (detail.code === 'UNKNOWN_USER') {
      return 'No user has this e-mail address. Only existing users can be added.';
    }
    if (detail.code === 'REQUIRED') {
      return 'Enter an e-mail address.';
    }
    return 'Enter a valid e-mail address.';
  }
  if (detail.pointer === '/role') {
    return 'Choose one of the roles ADMIN, MANAGER or REP.';
  }
  return `The request was refused (${detail.pointer ?? detail.parameter ?? 'request'}: ${detail.code}).`;
}

/** The message for a failed membership change; nothing is ever shown as changed that the server refused. */
export function failureMessage(error: unknown): string {
  if (!(error instanceof ApiProblem)) {
    return 'The API could not be reached. The change may not have been saved.';
  }
  if (error.status === 403) {
    return 'You do not have permission to do this. The list was reloaded.';
  }
  if (error.status === 404) {
    return 'This member was changed or removed by someone else; the list was reloaded.';
  }
  if (isConflict(error, 'LAST_ADMIN')) {
    return 'An organization needs at least one admin. Make another member an admin first. Nothing was changed.';
  }
  if (isConflict(error, 'MEMBERSHIP_EXISTS')) {
    return 'This user already has a membership in this organization (active or removed). Nothing was changed.';
  }
  if (error.status === 409) {
    return 'The change conflicts with the current state of the organization; the list was reloaded. Nothing was changed.';
  }
  if (error.status === 422) {
    return error.errors.length > 0 ? error.errors.map(fieldMessage).join(' ') : 'The request was refused as invalid.';
  }
  if (error.status === 429) {
    return `Too many requests. Try again in ${waitTime(error.retryAfterSeconds)}.`;
  }
  return `The change could not be saved (request ${error.requestId ?? 'unknown'}).`;
}
