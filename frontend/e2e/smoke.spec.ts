import { expect, test } from '@playwright/test';

// Browser journey through the edge: the SPA loads, calls the API and shows
// data read from PostgreSQL. MODE is "dev" (Vite) or "prod" (built SPA).
// Anonymous visitors see the login page, which shows the API status.
const mode = process.env.MODE ?? 'prod';

test('the login page loads and shows the API status read from the database', async ({ page }) => {
  const consoleErrors: string[] = [];
  page.on('console', (message) => {
    if (message.type() === 'error') {
      consoleErrors.push(message.text());
    }
  });
  const statusResponse = page.waitForResponse('**/api/v1/system/status');

  await page.goto('/');

  await expect(page).toHaveURL(/\/login$/);
  await expect(page.getByRole('heading', { name: 'Sign in' })).toBeVisible();
  const response = await statusResponse;
  expect(response.status()).toBe(200);
  const result = page.getByTestId('status-result');
  await expect(result).toContainText('flowcrm-api');
  await expect(result.locator('time')).toHaveAttribute('datetime', /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/);
  expect(consoleErrors).toEqual([]);
});

test('a client-side route is served by the SPA and kept for after the login', async ({ page }) => {
  const response = await page.goto('/accounts/some/deep/link');

  expect(response?.status()).toBe(200);
  await expect(page.getByRole('heading', { name: 'Sign in' })).toBeVisible();
  expect(new URL(page.url()).searchParams.get('returnTo')).toBe('/accounts/some/deep/link');
});

test('an unknown API route is a problem document, not the SPA', async ({ request }) => {
  const response = await request.get('/api/v1/does-not-exist');

  expect(response.status()).toBe(404);
  expect(response.headers()['content-type']).toBe('application/problem+json');
});

test('a failed login shows one generic message and sets no session cookie', async ({ page, context }) => {
  await page.goto('/login');
  await page.getByLabel('E-mail address').fill('nobody@example.test');
  await page.getByLabel('Password').fill('not the password at all');
  await page.getByRole('button', { name: 'Sign in' }).click();

  await expect(page.getByRole('alert')).toHaveText('The e-mail address or the password is wrong.');
  await expect(page.getByLabel('Password')).toHaveValue('');
  expect((await context.cookies()).filter((cookie) => cookie.name.endsWith('flowcrm_sid'))).toEqual([]);
});

test.describe('development only', () => {
  test.skip(mode !== 'dev', 'Hot module replacement exists only in the dev stack');

  test('the Vite HMR connection is established through the edge', async ({ page }) => {
    const connected = page.waitForEvent('console', {
      predicate: (message) => message.text().includes('[vite] connected'),
    });

    await page.goto('/');

    await connected;
  });
});
