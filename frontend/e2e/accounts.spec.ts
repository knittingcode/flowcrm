import { expect, type Page, test } from '@playwright/test';

/*
 * Accounts through the edge against the real API and PostgreSQL
 * (docs/product/MVP.md, AC-02, AC-09 to AC-11). The users and organizations
 * are the synthetic ones of tests/app/stack.sh; every run adds an account
 * with a name of its own, so runs do not depend on each other.
 *
 * Like the other logged-in journeys: in the development stack (MODE=dev) and
 * on the production build over HTTPS (MODE=https), not over the production
 * build's plain HTTP, where browsers refuse the Secure cookie.
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

test.describe('accounts', () => {
  test.skip(mode !== 'dev' && mode !== 'https', 'needs a session cookie the browser keeps (see above)');

  test('a member adds, opens and edits an account, and it is still there after signing in again', async ({ page }) => {
    const name = `Acme ${String(Date.now())}`;
    const consoleErrors: string[] = [];
    page.on('console', (message) => {
      if (message.type() === 'error') {
        consoleErrors.push(message.text());
      }
    });

    await signIn(page, env('E2E_REP_EMAIL'));
    await expect(page.getByRole('heading', { name: env('E2E_ORG_A_NAME') })).toBeVisible();
    await page.getByRole('navigation', { name: 'Sections' }).getByRole('link', { name: 'Accounts' }).click();
    await expect(page.getByRole('heading', { name: 'Accounts' })).toBeVisible();

    // The server validates: a website without a scheme is refused next to its field.
    await page.getByLabel('Name').fill(name);
    await page.getByLabel('Website (optional)').fill('acme.example.test');
    await page.getByRole('button', { name: 'Add account' }).click();
    await expect(page.getByText('Enter a web address that starts with http:// or https://.')).toBeVisible();

    await page.getByLabel('Website (optional)').fill('https://acme.example.test');
    await page.getByRole('button', { name: 'Add account' }).click();
    await expect(page.getByRole('status')).toContainText(`The account “${name}” was added.`);
    expect(consoleErrors.filter((text) => !text.includes('422'))).toEqual([]);

    await page.getByRole('table').getByRole('link', { name }).click();
    await expect(page.getByRole('heading', { name })).toBeVisible();
    await expect(page.getByRole('link', { name: 'https://acme.example.test' })).toBeVisible();
    await expect(page.getByRole('heading', { name: 'Archive' })).toHaveCount(0);

    await page.getByLabel('Name').fill(`${name} SA`);
    await page.getByLabel('Phone (optional)').fill('+48 22 123 45 67');
    await page.getByRole('button', { name: 'Save changes' }).click();
    await expect(page.getByRole('status')).toContainText('The changes were saved.');
    await expect(page.getByRole('heading', { name: `${name} SA` })).toBeVisible();
    const address = page.url();

    await page.getByRole('button', { name: 'Sign out' }).click();
    await expect(page.getByRole('heading', { name: 'Sign in' })).toBeVisible();
    await signIn(page, env('E2E_REP_EMAIL'), new URL(address).pathname);
    await expect(page.getByRole('heading', { name: `${name} SA` })).toBeVisible();
    await expect(page.getByText('+48 22 123 45 67')).toBeVisible();
  });

  test('an ADMIN archives an account; it leaves the list and can no longer be changed', async ({ page }) => {
    const name = `Archived ${String(Date.now())}`;
    await signIn(page, env('E2E_ADMIN_EMAIL'), `/o/${env('E2E_ORG_A')}/accounts`);
    await page.getByLabel('Name').fill(name);
    await page.getByRole('button', { name: 'Add account' }).click();
    await page.getByRole('table').getByRole('link', { name }).click();

    await page.getByRole('button', { name: 'Archive…' }).click();
    await page.getByRole('button', { name: 'Archive this account' }).click();
    await expect(page.getByText('This account is archived.')).toBeVisible();
    await expect(page.getByRole('button', { name: 'Save changes' })).toHaveCount(0);

    await page.getByRole('link', { name: 'All accounts' }).click();
    await expect(page.getByRole('heading', { name: 'Accounts' })).toBeVisible();
    await expect(page.getByRole('link', { name })).toHaveCount(0);
  });

  test("another organization's accounts look like an unknown page", async ({ page }) => {
    await signIn(page, env('E2E_REP_EMAIL'));
    await expect(page.getByRole('heading', { name: env('E2E_ORG_A_NAME') })).toBeVisible();

    await page.goto(`/o/${env('E2E_ORG_B')}/accounts`);
    await expect(page.getByRole('heading', { name: 'Not found' })).toBeVisible();

    const forged = await page.request.get(`/api/v1/organizations/${env('E2E_ORG_B')}/accounts`);
    expect(forged.status()).toBe(404);
  });
});
