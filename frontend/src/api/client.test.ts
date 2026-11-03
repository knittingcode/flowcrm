import { afterEach, describe, expect, it, vi } from 'vitest';
import { fakeApi, json, problem } from '../test/fakeApi.ts';
import { ApiProblem, apiRequest, onUnauthenticated, setCsrfRefresher, setCsrfToken } from './client.ts';

describe('apiRequest', () => {
  afterEach(() => {
    vi.unstubAllGlobals();
    setCsrfToken(null);
    setCsrfRefresher(null);
    onUnauthenticated(null);
  });

  it('sends the CSRF token on unsafe requests only, and JSON bodies', async () => {
    const calls = fakeApi({ 'GET /api/v1/me': json(200, {}), 'POST /api/v1/me/password': new Response(null, { status: 204 }) });
    setCsrfToken('token-1');

    await apiRequest('/api/v1/me', {}, () => null);
    await apiRequest('/api/v1/me/password', { method: 'POST', body: { a: 'b' } }, () => null);

    expect(calls[0]?.headers).toEqual({ Accept: 'application/json' });
    expect(calls[1]?.headers).toEqual({ Accept: 'application/json', 'Content-Type': 'application/json', 'X-CSRF-Token': 'token-1' });
    expect(calls[1]?.body).toEqual({ a: 'b' });
  });

  it('turns problem documents into ApiProblem with the request ID, errors and Retry-After', async () => {
    fakeApi({
      'POST /api/v1/auth/login': problem(429, 'too-many-requests', { 'Retry-After': '300' }),
      'GET /api/v1/x': json(422, { type: '/problems/validation-error', title: 'x', status: 422, requestId: 'r', errors: [{ parameter: 'page', code: 'OUT_OF_RANGE' }] }),
    });

    const limited = apiRequest('/api/v1/auth/login', { method: 'POST', body: {}, authenticating: true }, () => null);
    await expect(limited).rejects.toMatchObject({ status: 429, type: '/problems/too-many-requests', retryAfterSeconds: 300, requestId: '0192f0c4-7d1e-7b8a-9f3c-2b4d6e8f0a1c' });
    await expect(apiRequest('/api/v1/x', {}, () => null)).rejects.toMatchObject({ errors: [{ parameter: 'page', code: 'OUT_OF_RANGE' }] });
  });

  it('reports a 401 as the end of the session, except for the login itself', async () => {
    fakeApi({ 'GET /api/v1/me': problem(401, 'unauthenticated'), 'POST /api/v1/auth/login': problem(401, 'invalid-credentials') });
    const ended = vi.fn();
    onUnauthenticated(ended);

    await expect(apiRequest('/api/v1/auth/login', { method: 'POST', body: {}, authenticating: true }, () => null)).rejects.toBeInstanceOf(ApiProblem);
    expect(ended).not.toHaveBeenCalled();
    await expect(apiRequest('/api/v1/me', {}, () => null)).rejects.toMatchObject({ status: 401 });
    expect(ended).toHaveBeenCalledOnce();
  });

  it('retries an unsafe request once after csrf-invalid, with the refreshed token', async () => {
    const calls = fakeApi({ 'POST /api/v1/auth/logout': [problem(403, 'csrf-invalid'), new Response(null, { status: 204 })] });
    setCsrfToken('stale');
    setCsrfRefresher(() => {
      setCsrfToken('fresh');
      return Promise.resolve();
    });

    await apiRequest('/api/v1/auth/logout', { method: 'POST' }, () => null);

    expect(calls.map((c) => c.headers['X-CSRF-Token'])).toEqual(['stale', 'fresh']);
  });

  it('does not retry anything else', async () => {
    const calls = fakeApi({ 'POST /api/v1/auth/logout': problem(403, 'forbidden'), 'GET /api/v1/me': problem(403, 'csrf-invalid') });
    const refresher = vi.fn(() => Promise.resolve());
    setCsrfRefresher(refresher);

    await expect(apiRequest('/api/v1/auth/logout', { method: 'POST' }, () => null)).rejects.toMatchObject({ status: 403 });
    await expect(apiRequest('/api/v1/me', {}, () => null)).rejects.toMatchObject({ status: 403 });

    expect(refresher).not.toHaveBeenCalled();
    expect(calls).toHaveLength(2);
  });
});
