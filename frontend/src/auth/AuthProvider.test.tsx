import { act, render, screen } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { fakeApi, json, problem, session } from '../test/fakeApi.ts';
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
