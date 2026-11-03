/** One entry of a validation problem (422). */
export interface ProblemDetail {
  pointer?: string;
  parameter?: string;
  code: string;
}

/**
 * An RFC 9457 problem document of the API, or a response that could not be
 * read as one. `type` is the problem type, such as /problems/not-found.
 */
export class ApiProblem extends Error {
  readonly status: number;
  readonly type: string;
  readonly requestId: string | null;
  readonly errors: readonly ProblemDetail[];
  readonly retryAfterSeconds: number | null;

  constructor(
    status: number,
    type: string,
    title: string,
    requestId: string | null,
    errors: readonly ProblemDetail[],
    retryAfterSeconds: number | null,
  ) {
    super(title);
    this.name = 'ApiProblem';
    this.status = status;
    this.type = type;
    this.requestId = requestId;
    this.errors = errors;
    this.retryAfterSeconds = retryAfterSeconds;
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null;
}

function isProblemDetail(value: unknown): value is ProblemDetail {
  return isRecord(value) && typeof value.code === 'string';
}

async function problemOf(response: Response): Promise<ApiProblem> {
  const body: unknown = await response.json().catch(() => null);
  const retryAfter = Number.parseInt(response.headers.get('Retry-After') ?? '', 10);
  if (!isRecord(body)) {
    return new ApiProblem(response.status, 'about:blank', response.statusText, null, [], null);
  }
  return new ApiProblem(
    response.status,
    typeof body.type === 'string' ? body.type : 'about:blank',
    typeof body.title === 'string' ? body.title : response.statusText,
    typeof body.requestId === 'string' ? body.requestId : null,
    Array.isArray(body.errors) ? body.errors.filter(isProblemDetail) : [],
    Number.isFinite(retryAfter) ? retryAfter : null,
  );
}

/*
 * The CSRF token of the current session (ADR-019). It lives in memory only:
 * never in localStorage, sessionStorage or a cookie. The AuthProvider sets it
 * from every session response and clears it on logout.
 */
let csrfToken: string | null = null;
let unauthenticatedListener: (() => void) | null = null;
let csrfRefresher: (() => Promise<void>) | null = null;

export function setCsrfToken(token: string | null): void {
  csrfToken = token;
}

/** Called when a request answers 401: the session has ended on the server. */
export function onUnauthenticated(listener: (() => void) | null): void {
  unauthenticatedListener = listener;
}

/** Fetches a fresh CSRF token (the session's), used once after a csrf-invalid answer. */
export function setCsrfRefresher(refresher: (() => Promise<void>) | null): void {
  csrfRefresher = refresher;
}

const UNSAFE = new Set(['POST', 'PUT', 'PATCH', 'DELETE']);

export interface RequestOptions {
  method?: 'GET' | 'POST' | 'PUT' | 'PATCH' | 'DELETE';
  body?: unknown;
  signal?: AbortSignal;
  /** A 401 is the expected answer (login), not the end of a session. */
  authenticating?: boolean;
}

function send(path: string, options: RequestOptions): Promise<Response> {
  const method = options.method ?? 'GET';
  const headers: Record<string, string> = { Accept: 'application/json' };
  if (options.body !== undefined) {
    headers['Content-Type'] = 'application/json';
  }
  if (UNSAFE.has(method) && csrfToken !== null) {
    headers['X-CSRF-Token'] = csrfToken;
  }
  return fetch(path, {
    method,
    headers,
    credentials: 'same-origin',
    ...(options.body === undefined ? {} : { body: JSON.stringify(options.body) }),
    ...(options.signal === undefined ? {} : { signal: options.signal }),
  });
}

/**
 * Sends a request to the API on the same origin and reads its JSON answer
 * with `read` (null for 204). Problems are thrown as ApiProblem. An unsafe
 * request refused with csrf-invalid was not processed, so it is retried once
 * after fetching the session's current token; nothing else is retried.
 */
export async function apiRequest<T>(path: string, options: RequestOptions, read: (body: unknown) => T): Promise<T> {
  let response = await send(path, options);
  if (response.status === 403 && UNSAFE.has(options.method ?? 'GET') && csrfRefresher !== null) {
    const problem = await problemOf(response.clone());
    if (problem.type === '/problems/csrf-invalid') {
      await csrfRefresher();
      response = await send(path, options);
    }
  }
  if (!response.ok) {
    const problem = await problemOf(response);
    if (problem.status === 401 && options.authenticating !== true) {
      unauthenticatedListener?.();
    }
    throw problem;
  }
  if (response.status === 204) {
    return read(null);
  }
  const body: unknown = await response.json().catch(() => {
    throw new ApiProblem(response.status, 'about:blank', 'Unexpected response from the API', null, [], null);
  });
  return read(body);
}

/** For readers: fails with a problem when the body does not have the expected shape. */
export function unexpected(): never {
  throw new ApiProblem(200, 'about:blank', 'Unexpected response from the API', null, [], null);
}
