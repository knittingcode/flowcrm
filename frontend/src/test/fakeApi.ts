import { vi } from 'vitest';

export interface Call {
  method: string;
  path: string;
  headers: Record<string, string>;
  body: unknown;
}

type Answer = Response | (() => Response);

export function json(status: number, body: unknown, headers: Record<string, string> = {}): Response {
  const contentType = status >= 400 ? 'application/problem+json' : 'application/json';
  return new Response(JSON.stringify(body), { status, headers: { 'Content-Type': contentType, ...headers } });
}

export function problem(status: number, type: string, headers: Record<string, string> = {}): Response {
  return json(status, { type: `/problems/${type}`, title: type, status, instance: '/api', requestId: '0192f0c4-7d1e-7b8a-9f3c-2b4d6e8f0a1c' }, headers);
}

export const anonymous = (): Response => json(200, { authenticated: false });

export function session(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    authenticated: true,
    user: { id: 'u-1', email: 'ada@example.test', displayName: 'Ada Tester' },
    memberships: [
      {
        organizationId: 'org-a',
        organizationName: 'Alpha',
        membershipId: 'm-1',
        role: 'REP',
        permissions: ['organization.view', 'membership.list'],
      },
    ],
    csrfToken: 'token-1',
    expiresAt: '2026-10-23T16:00:00Z',
    ...overrides,
  };
}

/**
 * Replaces fetch with a table of answers keyed by "METHOD path"; a list is
 * answered in order (the last one repeats). Unknown requests fail the test.
 */
export function fakeApi(routes: Record<string, Answer | Answer[]>): Call[] {
  const calls: Call[] = [];
  const used: Record<string, number> = {};
  vi.stubGlobal(
    'fetch',
    vi.fn((input: RequestInfo | URL, init?: RequestInit) => {
      const method = init?.method ?? 'GET';
      const path = typeof input === 'string' ? input : input instanceof URL ? input.pathname + input.search : input.url;
      const headers = (init?.headers ?? {}) as Record<string, string>;
      calls.push({ method, path, headers, body: typeof init?.body === 'string' ? (JSON.parse(init.body) as unknown) : undefined });
      const key = `${method} ${path}`;
      const route = routes[key];
      if (route === undefined) {
        return Promise.reject(new Error(`unexpected request ${key}`));
      }
      const answers = Array.isArray(route) ? route : [route];
      const index = Math.min(used[key] ?? 0, answers.length - 1);
      used[key] = (used[key] ?? 0) + 1;
      const answer = answers[index];
      if (answer === undefined) {
        return Promise.reject(new Error(`no answer for ${key}`));
      }
      return Promise.resolve(typeof answer === 'function' ? answer() : answer.clone());
    }),
  );

  return calls;
}
