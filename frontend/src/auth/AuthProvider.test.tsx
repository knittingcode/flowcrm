import { act, render, screen } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { apiRequest, setCsrfToken } from '../api/client.ts';
import { anonymous, type Call, fakeApi, json, problem, session } from '../test/fakeApi.ts';
import { AuthProvider } from './AuthProvider.tsx';
import { type Auth, useAuth } from './context.ts';

/** Shows the state and hands out the context, so that logout() can be called and its promise observed. */
function renderProvider(): { auth: () => Auth } {
  let current: Auth | null = null;
  function Probe() {
    current = useAuth();
    const { state } = current;
    return <p data-testid="state">{state.status === 'anonymous' ? `anonymous ended=${String(state.ended)}` : state.status}</p>;
  }
  render(
    <AuthProvider>
      <Probe />
    </AuthProvider>,
  );
  return {
    auth: () => {
      if (current === null) {
        throw new Error('not rendered');
      }
      return current;
    },
  };
}

/*
 * The AuthProvider's own logout, without the AppShell: the global 401
 * listener also ends the state on a 401, so App-level tests pass whether
 * logout() resolves or rejects there. These tests pin the promise itself.
 */
describe('AuthProvider logout', () => {
  afterEach(() => {
    vi.unstubAllGlobals();
    setCsrfToken(null);
  });

  it('resolves on a 401, as the session has already ended on the server, and is signed out', async () => {
    fakeApi({
      'GET /api/v1/auth/session': json(200, session()),
      'POST /api/v1/auth/logout': problem(401, 'unauthenticated'),
    });
    const { auth } = renderProvider();
    expect(await screen.findByText('authenticated')).toBeInTheDocument();

    let outcome: Promise<void> = Promise.resolve();
    await act(async () => {
      outcome = auth().logout();
      await outcome.catch(() => undefined);
    });

    await expect(outcome).resolves.toBeUndefined();
    // Signed out by the user, not "the session has ended".
    expect(screen.getByTestId('state')).toHaveTextContent('anonymous ended=false');
  });

  it('resolves on a 204 and is signed out', async () => {
    fakeApi({
      'GET /api/v1/auth/session': json(200, session()),
      'POST /api/v1/auth/logout': new Response(null, { status: 204 }),
    });
    const { auth } = renderProvider();
    expect(await screen.findByText('authenticated')).toBeInTheDocument();

    let outcome: Promise<void> = Promise.resolve();
    await act(async () => {
      outcome = auth().logout();
      await outcome.catch(() => undefined);
    });

    await expect(outcome).resolves.toBeUndefined();
    expect(screen.getByTestId('state')).toHaveTextContent('anonymous ended=false');
  });

  it('rejects on a 500 and stays signed in, as the session may still be valid', async () => {
    fakeApi({
      'GET /api/v1/auth/session': json(200, session()),
      'POST /api/v1/auth/logout': problem(500, 'internal-error'),
    });
    const { auth } = renderProvider();
    expect(await screen.findByText('authenticated')).toBeInTheDocument();

    let outcome: Promise<void> = Promise.resolve();
    await act(async () => {
      outcome = auth().logout();
      await outcome.catch(() => undefined);
    });

    await expect(outcome).rejects.toMatchObject({ status: 500 });
    expect(screen.getByTestId('state')).toHaveTextContent('authenticated');
  });
});

/** The CSRF token header of the last request to `path`, or undefined when it was sent without one. */
function lastToken(calls: Call[], path: string): string | undefined {
  return calls.filter((c) => c.path === path).at(-1)?.headers['X-CSRF-Token'];
}

/*
 * The in-memory CSRF token (ADR-019) belongs to one session. Once the
 * session is over in the SPA, the next unsafe request (here: the next login)
 * must go out without it; nothing refetches a token then. While the session
 * may still be valid, the token is kept so that a retry can succeed.
 */
describe('AuthProvider CSRF token', () => {
  afterEach(() => {
    vi.unstubAllGlobals();
    setCsrfToken(null);
  });

  async function signIn(auth: () => Auth): Promise<void> {
    await act(async () => {
      await auth().login('ada@example.test', 'correct horse battery staple');
    });
  }

  it('is not sent after a logout answered 204', async () => {
    const calls = fakeApi({
      'GET /api/v1/auth/session': json(200, session()),
      'POST /api/v1/auth/logout': new Response(null, { status: 204 }),
      'POST /api/v1/auth/login': json(200, session({ csrfToken: 'token-2' })),
    });
    const { auth } = renderProvider();
    expect(await screen.findByText('authenticated')).toBeInTheDocument();
    await act(async () => {
      await auth().logout();
    });
    expect(screen.getByTestId('state')).toHaveTextContent('anonymous ended=false');

    await signIn(auth);

    expect(lastToken(calls, '/api/v1/auth/logout')).toBe('token-1');
    expect(lastToken(calls, '/api/v1/auth/login')).toBeUndefined();
  });

  it('is not sent after a logout answered 401', async () => {
    const calls = fakeApi({
      'GET /api/v1/auth/session': json(200, session()),
      'POST /api/v1/auth/logout': problem(401, 'unauthenticated'),
      'POST /api/v1/auth/login': json(200, session({ csrfToken: 'token-2' })),
    });
    const { auth } = renderProvider();
    expect(await screen.findByText('authenticated')).toBeInTheDocument();
    await act(async () => {
      await auth().logout();
    });

    await signIn(auth);

    expect(lastToken(calls, '/api/v1/auth/login')).toBeUndefined();
  });

  it('is not sent after another request answered 401, as the session has ended on the server', async () => {
    const calls = fakeApi({
      'GET /api/v1/auth/session': json(200, session()),
      'GET /api/v1/me': problem(401, 'unauthenticated'),
      'POST /api/v1/auth/login': json(200, session({ csrfToken: 'token-2' })),
    });
    const { auth } = renderProvider();
    expect(await screen.findByText('authenticated')).toBeInTheDocument();
    await act(async () => {
      await apiRequest('/api/v1/me', {}, () => null).catch(() => undefined);
    });
    expect(screen.getByTestId('state')).toHaveTextContent('anonymous ended=true');

    await signIn(auth);

    expect(lastToken(calls, '/api/v1/auth/login')).toBeUndefined();
  });

  it('is not sent after the session was read again as anonymous', async () => {
    const calls = fakeApi({
      'GET /api/v1/auth/session': [json(200, session()), anonymous()],
      'POST /api/v1/auth/login': json(200, session({ csrfToken: 'token-2' })),
    });
    const { auth } = renderProvider();
    expect(await screen.findByText('authenticated')).toBeInTheDocument();
    await act(async () => {
      await auth().refresh();
    });
    expect(screen.getByTestId('state')).toHaveTextContent('anonymous ended=false');

    await signIn(auth);

    expect(lastToken(calls, '/api/v1/auth/login')).toBeUndefined();
  });

  const failures: [string, () => Response][] = [
    [
      'the connection fails',
      () => {
        throw new TypeError('Failed to fetch');
      },
    ],
    ['the API answers 500', () => problem(500, 'internal-error')],
  ];
  it.each(failures)('is kept for the retry when a logout does not complete because %s', async (_, failure) => {
    const calls = fakeApi({
      'GET /api/v1/auth/session': json(200, session()),
      'POST /api/v1/auth/logout': [failure, new Response(null, { status: 204 })],
    });
    const { auth } = renderProvider();
    expect(await screen.findByText('authenticated')).toBeInTheDocument();
    await act(async () => {
      await auth().logout().catch(() => undefined);
    });
    expect(screen.getByTestId('state')).toHaveTextContent('authenticated');

    await act(async () => {
      await auth().logout();
    });

    expect(calls.filter((c) => c.path === '/api/v1/auth/logout').map((c) => c.headers['X-CSRF-Token'])).toEqual(['token-1', 'token-1']);
    expect(screen.getByTestId('state')).toHaveTextContent('anonymous ended=false');
  });
});
