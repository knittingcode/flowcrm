import { expect, type Page, test } from '@playwright/test';

/*
 * The member administration against the real API and PostgreSQL
 * (FCRM-FND-010C), with the synthetic users and organizations of the stack
 * test (tests/app/lib.sh seed_e2e). Other specs rely on the seeded
 * memberships (Alpha: Admin ADMIN, Rep REP, Multi REP): only the seeded user
 * Spare, who has no membership, is added, changed and removed again; every
 * other change tried here is one the server refuses.
 *
 * Like auth.spec.ts in the development stack (MODE=dev) and on the
 * production build over HTTPS (MODE=https).
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

async function openMembers(page: Page, email: string) {
  await signIn(page, email, `/o/${env('E2E_ORG_A')}`);
  await page.getByRole('link', { name: 'Open the members page' }).click();
  await expect(page).toHaveURL(new RegExp(`/o/${env('E2E_ORG_A')}/members$`));
  await expect(page.getByRole('heading', { name: `Members of ${env('E2E_ORG_A_NAME')}` })).toBeVisible();
  await expect(page.getByRole('table')).toContainText('Admin Tester');
}

interface Member {
  membershipId: string;
  displayName: string;
  role: string;
}

async function membersOf(page: Page): Promise<Member[]> {
  const response = await page.request.get(`/api/v1/organizations/${env('E2E_ORG_A')}/members?pageSize=100`);
  expect(response.status()).toBe(200);
  return ((await response.json()) as { data: Member[] }).data;
}

test.describe('member administration', () => {
  test.skip(mode !== 'dev' && mode !== 'https', 'needs a session cookie the browser keeps (see auth.spec.ts)');

  test('an ADMIN has the controls; an existing membership or an unknown user changes nothing', async ({ page }) => {
    await openMembers(page, env('E2E_ADMIN_EMAIL'));

    await expect(page.getByRole('form', { name: 'Add a member' })).toBeVisible();
    await expect(page.getByRole('button', { name: 'Change role of Rep Tester' })).toBeVisible();
    await expect(page.getByRole('button', { name: 'Remove Rep Tester' })).toBeVisible();
    const before = await membersOf(page);

    await page.getByLabel('E-mail address of the user').fill(env('E2E_REP_EMAIL'));
    await page.getByRole('button', { name: 'Add member' }).click();
    await expect(page.getByRole('alert')).toContainText('This user already has a membership in this organization');

    await page.getByLabel('E-mail address of the user').fill(`nobody-${String(Date.now())}@example.test`);
    await page.getByRole('button', { name: 'Add member' }).click();
    const email = page.getByLabel('E-mail address of the user');
    await expect(email).toBeFocused();
    await expect(email).toHaveAttribute('aria-invalid', 'true');
    await expect(page.getByText('No user has this e-mail address.').first()).toBeVisible();

    // The confirmation of a removal can be left without removing anyone.
    await page.getByRole('button', { name: 'Remove Rep Tester' }).click();
    await expect(page.getByRole('group', { name: `Remove Rep Tester from ${env('E2E_ORG_A_NAME')}?` })).toBeVisible();
    await page.keyboard.press('Escape');
    await expect(page.getByRole('button', { name: 'Remove Rep Tester' })).toBeFocused();

    expect(await membersOf(page)).toEqual(before);
  });

  test('a REP has no controls, and a forged change is refused', async ({ page }) => {
    await openMembers(page, env('E2E_REP_EMAIL'));

    await expect(page.getByRole('form', { name: 'Add a member' })).toHaveCount(0);
    await expect(page.getByRole('button', { name: /^(Change role of|Remove) / })).toHaveCount(0);
    await expect(page.getByRole('columnheader', { name: 'Actions' })).toHaveCount(0);

    const before = await membersOf(page);
    const admin = before.find((m) => m.displayName === 'Admin Tester');
    expect(admin).toBeDefined();
    const session = (await (await page.request.get('/api/v1/auth/session')).json()) as { csrfToken: string };
    const headers = { Origin: new URL(page.url()).origin, 'X-CSRF-Token': session.csrfToken };
    const path = `/api/v1/organizations/${env('E2E_ORG_A')}/members`;

    for (const forged of [
      await page.request.patch(`${path}/${admin?.membershipId ?? ''}`, { headers, data: { role: 'REP' } }),
      await page.request.delete(`${path}/${admin?.membershipId ?? ''}`, { headers }),
      await page.request.post(path, { headers, data: { email: env('E2E_REP_EMAIL'), role: 'ADMIN' } }),
    ]) {
      expect(forged.status(), forged.url()).toBe(403);
      expect(((await forged.json()) as { type: string }).type).toBe('/problems/forbidden');
    }
    expect(await membersOf(page)).toEqual(before);
  });

  test('an ADMIN adds a member, changes the role and removes the member again', async ({ page }) => {
    await openMembers(page, env('E2E_ADMIN_EMAIL'));
    const before = await membersOf(page);

    await page.getByLabel('E-mail address of the user').fill(env('E2E_SPARE_EMAIL'));
    await page.getByLabel('Role', { exact: true }).selectOption('REP');
    await page.getByRole('button', { name: 'Add member' }).click();
    const table = page.getByRole('table');
    await expect(table).toContainText('Spare Tester');
    const added = (await membersOf(page)).find((m) => m.displayName === 'Spare Tester');
    expect(added).toMatchObject({ role: 'REP' });

    await page.getByLabel('New role for Spare Tester').selectOption('MANAGER');
    await page.getByRole('button', { name: 'Change role of Spare Tester' }).click();
    await expect.poll(async () => (await membersOf(page)).find((m) => m.displayName === 'Spare Tester')?.role).toBe('MANAGER');
    await expect(page.getByLabel('New role for Spare Tester')).toHaveValue('MANAGER');

    await page.getByRole('button', { name: 'Remove Spare Tester' }).click();
    await page.getByRole('button', { name: 'Yes, remove Spare Tester' }).click();
    await expect(table).not.toContainText('Spare Tester');
    expect(await membersOf(page)).toEqual(before);
  });

  test('the only ADMIN cannot demote themselves', async ({ page }) => {
    await openMembers(page, env('E2E_ADMIN_EMAIL'));
    const before = await membersOf(page);
    expect(before.filter((m) => m.role === 'ADMIN').map((m) => m.displayName)).toEqual(['Admin Tester']);

    await page.getByLabel('New role for Admin Tester').selectOption('REP');
    await expect(page.getByText('This is your own membership.')).toBeVisible();
    await page.getByRole('button', { name: 'Change role of Admin Tester' }).click();

    await expect(page.getByRole('alert')).toContainText('An organization needs at least one admin.');
    await expect(page.getByLabel('New role for Admin Tester')).toHaveValue('ADMIN');
    await expect(page.getByRole('form', { name: 'Add a member' })).toBeVisible();
    expect(await membersOf(page)).toEqual(before);
  });
});
