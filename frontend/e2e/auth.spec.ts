import { expect, type Page, test } from '@playwright/test';

/*
 * Logged-in journeys through the edge against the real API and PostgreSQL
 * (FCRM-FND-010B). The users and organizations are synthetic and created by
 * the stack test with the operator console (tests/app/stack.sh); their
 * addresses and the shared password come from the environment.
 *
 * Only in the development stack: a session needs its cookie, and the
 * production-like edge serves plain HTTP, where browsers refuse the Secure
 * __Host-flowcrm_sid cookie (its attributes are checked there with curl,
 * tests/app/prodlike.sh PL-16).
 */
const mode = process.env.MODE ?? 'prod';

function env(name: string): string {
  const value = process.env[name];
  if (value === undefined || value === '') {
    throw new Error(`${name} is not set (tests/app/stack.sh seeds the users)`);
  }
  return value;
}

async function signIn(page: Page, email: string, path = '/') {
  await page.goto(path);
  await expect(page.getByRole('heading', { name: 'Sign in' })).toBeVisible();
  await page.getByLabel('E-mail address').fill(email);
  await page.getByLabel('Password').fill(env('E2E_PASSWORD'));
  await page.getByLabel('Password').press('Enter');
}

test.describe('logged in', () => {
  test.skip(mode !== 'dev', 'needs the session cookie over plain HTTP (see above)');

  test('a deep link leads through the login back to the organization; logout ends the session', async ({ page, context }) => {
    const consoleErrors: string[] = [];
    page.on('console', (message) => {
      if (message.type() === 'error') {
        consoleErrors.push(message.text());
      }
    });

    await signIn(page, env('E2E_REP_EMAIL'), `/o/${env('E2E_ORG_A')}`);

    await expect(page).toHaveURL(new RegExp(`/o/${env('E2E_ORG_A')}$`));
    await expect(page.getByRole('heading', { name: env('E2E_ORG_A_NAME') })).toBeVisible();
    await expect(page.getByRole('table')).toContainText('Rep Tester');
    const cookie = (await context.cookies()).find((c) => c.name === 'flowcrm_sid');
    expect(cookie).toMatchObject({ httpOnly: true, sameSite: 'Lax', path: '/', secure: false });
    expect(consoleErrors).toEqual([]);

    await page.getByRole('button', { name: 'Sign out' }).click();
    await expect(page.getByRole('heading', { name: 'Sign in' })).toBeVisible();
    expect((await page.request.get('/api/v1/me')).status()).toBe(401);

    // The organization's address again (as a bookmark or the history would
    // open it): only the login, no data.
    await page.goto(`/o/${env('E2E_ORG_A')}`);
    await expect(page.getByRole('heading', { name: 'Sign in' })).toBeVisible();
    await expect(page.getByText(env('E2E_ORG_A_NAME'))).toHaveCount(0);
  });

  test('e-mail addresses are shown to an ADMIN, not to a REP', async ({ browser }) => {
    for (const [email, visible] of [
      [env('E2E_ADMIN_EMAIL'), true],
      [env('E2E_REP_EMAIL'), false],
    ] as const) {
      const context = await browser.newContext();
      const page = await context.newPage();
      await signIn(page, email);
      const table = page.getByRole('table');
      await expect(table).toContainText('Admin Tester');
      await expect(table.getByRole('columnheader', { name: 'E-mail address' })).toHaveCount(visible ? 1 : 0);
      await expect(table.getByText(env('E2E_ADMIN_EMAIL'))).toHaveCount(visible ? 1 : 0);
      await context.close();
    }
  });

  test('a member of two organizations chooses, and has the role of each', async ({ page }) => {
    await signIn(page, env('E2E_MULTI_EMAIL'));

    await expect(page.getByRole('heading', { name: 'Organizations' })).toBeVisible();
    await page.getByRole('main').getByRole('link', { name: env('E2E_ORG_B_NAME') }).click();
    await expect(page.getByRole('heading', { name: env('E2E_ORG_B_NAME') })).toBeVisible();
    await expect(page.getByRole('table').getByRole('columnheader', { name: 'E-mail address' })).toHaveCount(1);

    await page.getByRole('navigation', { name: 'Organizations' }).getByRole('link', { name: env('E2E_ORG_A_NAME') }).click();
    await expect(page.getByRole('heading', { name: env('E2E_ORG_A_NAME') })).toBeVisible();
    await expect(page.getByRole('table').getByRole('columnheader', { name: 'E-mail address' })).toHaveCount(0);
  });

  test('another organization looks like an unknown page', async ({ page }) => {
    await signIn(page, env('E2E_REP_EMAIL'));
    await expect(page.getByRole('heading', { name: env('E2E_ORG_A_NAME') })).toBeVisible();

    await page.goto(`/o/${env('E2E_ORG_B')}`);

    await expect(page.getByRole('heading', { name: 'Not found' })).toBeVisible();
  });

  test('an unsafe request without the CSRF token is refused and the session stays', async ({ page }) => {
    await signIn(page, env('E2E_REP_EMAIL'));
    await expect(page.getByRole('heading', { name: env('E2E_ORG_A_NAME') })).toBeVisible();

    const forged = await page.request.post('/api/v1/auth/logout', { headers: { Origin: new URL(page.url()).origin } });

    expect(forged.status()).toBe(403);
    expect(((await forged.json()) as { type: string }).type).toBe('/problems/csrf-invalid');
    expect((await page.request.get('/api/v1/me')).status()).toBe(200);
  });
});
