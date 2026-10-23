import { networkInterfaces } from 'node:os';
import { expect, type Page, test } from '@playwright/test';

/*
 * The production session cookie in a real browser over HTTPS (MODE=https,
 * tests/app/prodlike.sh): the production build behind the production edge
 * configuration, with TLS terminated by the edge (BASE_URL
 * https://flowcrm.test:8443), the same edge over plain HTTP (HTTP_URL) and a
 * page of another site (ATTACKER_URL). Users and organizations are
 * synthetic, seeded with the operator console.
 */
const mode = process.env.MODE ?? 'prod';

function env(name: string): string {
  const value = process.env[name];
  if (value === undefined || value === '') {
    throw new Error(`${name} is not set (tests/app/prodlike.sh)`);
  }
  return value;
}

async function signIn(page: Page) {
  await page.goto('/');
  await expect(page.getByRole('heading', { name: 'Sign in' })).toBeVisible();
  await page.getByLabel('E-mail address').fill(env('E2E_REP_EMAIL'));
  await page.getByLabel('Password').fill(env('E2E_PASSWORD'));
  await page.getByLabel('Password').press('Enter');
  await expect(page.getByRole('heading', { name: env('E2E_ORG_A_NAME') })).toBeVisible();
}

type Init = { method?: string; headers?: Record<string, string>; body?: string };

/** The status of a request the page itself makes (the browser decides about cookies). */
async function status(page: Page, path: string, init: Init = {}): Promise<number> {
  return page.evaluate(async ({ p, i }) => (await fetch(p, i)).status, { p: path, i: init });
}

test.describe('over HTTPS', () => {
  test.skip(mode !== 'https', 'needs the HTTPS test edge (tests/app/prodlike.sh)');

  test('the session cookie is __Host-, Secure, HttpOnly, SameSite=Lax, Path=/ and host-only', async ({ page, context }) => {
    await signIn(page);

    const cookies = (await context.cookies()).filter((c) => c.name.includes('flowcrm_sid'));
    expect(cookies).toHaveLength(1);
    expect(cookies[0]).toMatchObject({
      name: '__Host-flowcrm_sid',
      domain: 'flowcrm.test',
      path: '/',
      secure: true,
      httpOnly: true,
      sameSite: 'Lax',
      expires: -1,
    });
    expect(await page.evaluate(() => document.cookie)).not.toContain('flowcrm_sid');
    expect(await status(page, '/api/v1/me')).toBe(200);

    await page.getByRole('button', { name: 'Sign out' }).click();
    await expect(page.getByRole('heading', { name: 'Sign in' })).toBeVisible();
    expect(await status(page, '/api/v1/me')).toBe(401);
    expect((await context.cookies()).filter((c) => c.name.includes('flowcrm_sid'))).toEqual([]);
  });

  test('the session cookie never travels over plain HTTP', async ({ page, context }) => {
    await signIn(page);

    expect(await context.cookies(env('HTTP_URL'))).toEqual([]);
    const plain = await page.goto(`${env('HTTP_URL')}/api/v1/auth/session`);
    expect(await plain?.json()).toEqual({ authenticated: false });

    await page.goto('/');
    await expect(page.getByRole('heading', { name: env('E2E_ORG_A_NAME') })).toBeVisible();
  });

  test('a login over plain HTTP leaves no cookie: the browser refuses the Secure cookie', async ({ page, context }) => {
    await page.goto(`${env('HTTP_URL')}/login`);
    await expect(page.getByRole('heading', { name: 'Sign in' })).toBeVisible();

    const login = await status(page, '/api/v1/auth/login', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ email: env('E2E_REP_EMAIL'), password: env('E2E_PASSWORD') }),
    });

    expect(login).toBe(200);
    expect((await context.cookies()).filter((c) => c.name.includes('flowcrm_sid'))).toEqual([]);
    const session: unknown = await page.evaluate(async () => (await fetch('/api/v1/auth/session')).json() as Promise<unknown>);
    expect(session).toEqual({ authenticated: false });
  });

  test('requests forged by another site are refused and the session stays', async ({ page, context }) => {
    await signIn(page);
    const attacker = await context.newPage();
    await attacker.goto(env('ATTACKER_URL'));

    const fetched = attacker.waitForResponse((r) => r.url().endsWith('/api/v1/auth/logout'));
    expect(await attacker.evaluate(() => (window as unknown as { forgedFetch: () => Promise<string> }).forgedFetch())).toBe('opaque');
    expect((await fetched).status()).toBe(403);

    for (const [form, path, expected, type] of [
      ['#logout', '/api/v1/auth/logout', 403, '/problems/csrf-invalid'],
      ['#password', '/api/v1/me/password', 415, '/problems/unsupported-media-type'],
    ] as const) {
      await attacker.goto(env('ATTACKER_URL'));
      const answer = attacker.waitForResponse((r) => r.url().endsWith(path));
      await attacker.locator(form).evaluate((f) => {
        (f as HTMLFormElement).submit();
      });
      const response = await answer;
      expect(response.status(), form).toBe(expected);
      expect(((await response.json()) as { type: string }).type, form).toBe(type);
    }

    expect(await status(page, '/api/v1/me')).toBe(200);
  });

  test('the API sees the browser as the client; a forwarded address it sends is ignored', async ({ page }) => {
    await page.goto('/login');
    const login = await status(page, '/api/v1/auth/login', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-Forwarded-For': '203.0.113.50', 'X-Forwarded-Proto': 'http' },
      body: JSON.stringify({ email: `nobody-${String(Date.now())}@example.test`, password: 'not the password' }),
    });

    expect(login).toBe(401);
    // tests/app/prodlike.sh matches the security log's client pseudonym with this address.
    const address = Object.values(networkInterfaces())
      .flat()
      .find((a) => a !== undefined && a.family === 'IPv4' && !a.internal)?.address;
    expect(address).toBeDefined();
    console.log(`browser-client-ip=${address ?? ''}`);
  });
});
