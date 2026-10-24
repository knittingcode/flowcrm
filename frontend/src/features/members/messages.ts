import { ApiProblem, type ProblemDetail } from '../../api/client.ts';
import { isConflict } from '../../api/memberships.ts';

/** The problem type of a request whose CSRF token or Origin was refused (RequestOriginGuard); it was not processed. */
const CSRF_INVALID = '/problems/csrf-invalid';

/**
 * A server error (5xx), from the API or from the edge (such as a 502 or 504
 * when PHP-FPM failed or timed out): the change may have been committed. The
 * API also answers 500 when an error happens after the commit, for example
 * while the member is read for the answer (docs/membership-administration.md).
 */
function serverError(error: ApiProblem): boolean {
  return error.status >= 500;
}

/**
 * Whether it is unknown if the change was saved: no answer arrived (the
 * connection failed, timed out or was aborted, possibly after the request had
 * been processed), the API answered with success but a body that could not
 * be read, or it answered with a server error.
 */
function outcomeUnknown(error: unknown): boolean {
  return !(error instanceof ApiProblem) || (error.status >= 200 && error.status < 300) || serverError(error);
}

/**
 * Answers after which the list may no longer be what the server has: it is
 * read again. A refused CSRF token is not among them: the request was not
 * processed, so the list is unchanged.
 */
export function needsReload(error: unknown): boolean {
  if (outcomeUnknown(error)) {
    return true;
  }
  return (
    error instanceof ApiProblem &&
    error.type !== CSRF_INVALID &&
    (error.status === 403 || error.status === 404 || error.status === 409)
  );
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

/**
 * Refusals after which the user's own access may have changed (a 403 other
 * than csrf-invalid: the role was lowered; a 404: the membership or the
 * organization is gone): the session is read again, so that the organization
 * switcher and the start page follow the server.
 */
export function accessMayHaveChanged(error: unknown): boolean {
  return error instanceof ApiProblem && ((error.status === 403 && error.type !== CSRF_INVALID) || error.status === 404);
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
    return 'The connection to the API failed before an answer arrived, so it is not known whether the change was saved. The list is read again to show the current state.';
  }
  if (serverError(error) && error.type === 'about:blank') {
    return `The API did not answer properly (status ${String(error.status)}), so it is not known whether the change was saved. The list is read again to show the current state.`;
  }
  if (serverError(error)) {
    return `The API reported an error (status ${String(error.status)}, request ${error.requestId ?? 'unknown'}), so it is not known whether the change was saved. The list is read again to show the current state.`;
  }
  if (outcomeUnknown(error)) {
    return 'The answer of the API could not be read, so it is not known whether the change was saved. The list is read again to show the current state.';
  }
  if (error.status === 403 && error.type === CSRF_INVALID) {
    return 'The security token of your session could not be verified, so nothing was changed. Reload the page or sign in again, then try again.';
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
