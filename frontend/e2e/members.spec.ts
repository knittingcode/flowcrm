import { expect, type Page, test } from '@playwright/test';

/*
 * The member administration against the real API and PostgreSQL
 * (FCRM-FND-010C), with the synthetic users and organizations of the stack
 * test (tests/app/lib.sh seed_e2e). Other specs rely on the seeded
 * memberships (Alpha: Admin ADMIN, Rep REP, Multi REP): only the seeded users
 * Spare and Deputy, who have no membership, are added, changed and removed
 * again; every other change tried here is one the server refuses.
 *
 * Organization B (Other ADMIN, Multi MANAGER) is only read: by its MANAGER,
 * and by the ADMIN of A, to whom it is unknown.
 *
 * Like auth.spec.ts in the development stack (MODE=dev) and on the
 * production build over HTTPS (MODE=https).
 *
 * Each run needs a fresh seed: the removed memberships of Spare and Deputy stay
 * REMOVED and cannot be added again (no reactivation, 409 MEMBERSHIP_EXISTS),
 * and a failure between an add and its removal leaves the user ACTIVE. stack.sh and
 * prodlike.sh seed new users for every run, and Playwright does not retry.
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

async function openMembers(page: Page, email: string, org = 'A') {
  await signIn(page, email, `/o/${env(`E2E_ORG_${org}`)}`);
  await page.getByRole('link', { name: 'Open the members page' }).click();
  await expect(page).toHaveURL(new RegExp(`/o/${env(`E2E_ORG_${org}`)}/members$`));
  await expect(page.getByRole('heading', { name: `Members of ${env(`E2E_ORG_${org}_NAME`)}` })).toBeVisible();
  await expect(page.getByRole('table')).toContainText(org === 'A' ? 'Admin Tester' : 'Other Tester');
}

interface Member {
  membershipId: string;
  displayName: string;
  role: string;
}

async function membersOf(page: Page, org = 'A'): Promise<Member[]> {
  const response = await page.request.get(`/api/v1/organizations/${env(`E2E_ORG_${org}`)}/members?pageSize=100`);
  expect(response.status()).toBe(200);
  return ((await response.json()) as { data: Member[] }).data;
}

/** The headers of an unsafe request of this page's session: its origin and CSRF token. */
async function unsafeHeaders(page: Page): Promise<Record<string, string>> {
  const session = (await (await page.request.get('/api/v1/auth/session')).json()) as { csrfToken: string };
  return { Origin: new URL(page.url()).origin, 'X-CSRF-Token': session.csrfToken };
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
    const headers = await unsafeHeaders(page);
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

  test('a MANAGER sees the e-mail addresses but has no controls, and a forged change is refused', async ({ page }) => {
    // Multi is MANAGER in organization B (and REP in A).
    await openMembers(page, env('E2E_MULTI_EMAIL'), 'B');

    await expect(page.getByRole('columnheader', { name: 'E-mail address' })).toHaveCount(1);
    await expect(page.getByRole('form', { name: 'Add a member' })).toHaveCount(0);
    await expect(page.getByRole('button', { name: /^(Change role of|Remove) / })).toHaveCount(0);
    await expect(page.getByRole('columnheader', { name: 'Actions' })).toHaveCount(0);

    const before = await membersOf(page, 'B');
    const admin = before.find((m) => m.displayName === 'Other Tester');
    expect(admin).toMatchObject({ role: 'ADMIN' });
    const headers = await unsafeHeaders(page);
    const path = `/api/v1/organizations/${env('E2E_ORG_B')}/members`;

    for (const forged of [
      await page.request.patch(`${path}/${admin?.membershipId ?? ''}`, { headers, data: { role: 'REP' } }),
      await page.request.delete(`${path}/${admin?.membershipId ?? ''}`, { headers }),
      await page.request.post(path, { headers, data: { email: env('E2E_SPARE_EMAIL'), role: 'REP' } }),
    ]) {
      expect(forged.status(), forged.url()).toBe(403);
      expect(((await forged.json()) as { type: string }).type).toBe('/problems/forbidden');
    }
    expect(await membersOf(page, 'B')).toEqual(before);
  });

  test("another organization's members page and memberships look unknown", async ({ browser, page }) => {
    // The membership IDs of organization B, read by its MANAGER in a separate session.
    const other = await browser.newContext();
    const multi = await other.newPage();
    await openMembers(multi, env('E2E_MULTI_EMAIL'), 'B');
    const membersOfB = await membersOf(multi, 'B');
    const target = membersOfB.find((m) => m.displayName === 'Other Tester');
    expect(target).toBeDefined();

    // The ADMIN of A has no membership in B.
    await openMembers(page, env('E2E_ADMIN_EMAIL'));
    const before = await membersOf(page);
    await page.goto(`/o/${env('E2E_ORG_B')}/members`);
    await expect(page.getByRole('heading', { name: 'Not found' })).toBeVisible();
    await expect(page.getByText(env('E2E_ORG_B_NAME'))).toHaveCount(0);
    await expect(page.getByText('Other Tester')).toHaveCount(0);

    const headers = await unsafeHeaders(page);
    const id = target?.membershipId ?? '';
    for (const forged of [
      await page.request.get(`/api/v1/organizations/${env('E2E_ORG_B')}/members`),
      await page.request.patch(`/api/v1/organizations/${env('E2E_ORG_B')}/members/${id}`, { headers, data: { role: 'REP' } }),
      await page.request.delete(`/api/v1/organizations/${env('E2E_ORG_B')}/members/${id}`, { headers }),
      // B's membership through A's own address: also unknown.
      await page.request.patch(`/api/v1/organizations/${env('E2E_ORG_A')}/members/${id}`, { headers, data: { role: 'REP' } }),
      await page.request.delete(`/api/v1/organizations/${env('E2E_ORG_A')}/members/${id}`, { headers }),
    ]) {
      expect(forged.status(), forged.url()).toBe(404);
      expect(((await forged.json()) as { type: string }).type).toBe('/problems/not-found');
    }

    expect(await membersOf(multi, 'B')).toEqual(membersOfB);
    expect(await membersOf(page)).toEqual(before);
    await other.close();
  });

  test('a change after the session has ended leads to the login and changes nothing; signing out leaves no data', async ({ page }) => {
    await openMembers(page, env('E2E_ADMIN_EMAIL'));
    const before = await membersOf(page);

    // The session ends on the server (as after an expiry or a logout elsewhere).
    const ended = await page.request.post('/api/v1/auth/logout', { headers: await unsafeHeaders(page) });
    expect(ended.status()).toBe(204);

    await page.getByLabel('New role for Rep Tester').selectOption('MANAGER');
    await page.getByRole('button', { name: 'Change role of Rep Tester' }).click();
    await expect(page.getByRole('heading', { name: 'Sign in' })).toBeVisible();
    await expect(page.getByText('Your session has ended. Please sign in again.')).toBeVisible();
    await expect(page.getByText('Rep Tester')).toHaveCount(0);

    await openMembers(page, env('E2E_ADMIN_EMAIL'));
    expect(await membersOf(page)).toEqual(before);

    await page.getByRole('button', { name: 'Sign out' }).click();
    await expect(page.getByRole('heading', { name: 'Sign in' })).toBeVisible();
    await page.goto(`/o/${env('E2E_ORG_A')}/members`);
    await expect(page.getByRole('heading', { name: 'Sign in' })).toBeVisible();
    await expect(page.getByText('Rep Tester')).toHaveCount(0);
    expect((await page.request.get(`/api/v1/organizations/${env('E2E_ORG_A')}/members`)).status()).toBe(401);
  });

  test('a sign-out without an answer keeps the members page and says so; the next step follows the server', async ({ page }) => {
    const members = new RegExp(`/o/${env('E2E_ORG_A')}/members$`);
    const signedOutFailed = 'Signing out did not complete. You may still be signed in, so try again.';
    await openMembers(page, env('E2E_ADMIN_EMAIL'));

    // 1. The logout never reaches the server: the session is still valid.
    await page.route('**/api/v1/auth/logout', (route) => route.abort('connectionreset'));
    await page.getByRole('button', { name: 'Sign out' }).click();
    await expect(page.getByRole('alert')).toHaveText(signedOutFailed);
    await expect(page).toHaveURL(members);
    await expect(page.getByRole('button', { name: 'Remove Rep Tester' })).toBeEnabled();
    expect((await page.request.get('/api/v1/me')).status()).toBe(200);

    // Signing out again, with an answer, ends the session.
    await page.unroute('**/api/v1/auth/logout');
    await page.getByRole('button', { name: 'Sign out' }).click();
    await expect(page.getByRole('heading', { name: 'Sign in' })).toBeVisible();
    expect((await page.request.get('/api/v1/me')).status()).toBe(401);

    // 2. The logout is processed but its answer is lost: the page cannot know,
    // so it says the same; the next request finds the session ended.
    await openMembers(page, env('E2E_ADMIN_EMAIL'));
    const before = await membersOf(page);
    await page.route('**/api/v1/auth/logout', async (route) => {
      expect((await route.fetch()).status()).toBe(204);
      await route.abort('connectionreset');
    });
    await page.getByRole('button', { name: 'Sign out' }).click();
    await expect(page.getByRole('alert')).toHaveText(signedOutFailed);
    await expect(page).toHaveURL(members);
    await page.unroute('**/api/v1/auth/logout');
    await page.getByLabel('New role for Rep Tester').selectOption('MANAGER');
    await page.getByRole('button', { name: 'Change role of Rep Tester' }).click();
    await expect(page.getByRole('heading', { name: 'Sign in' })).toBeVisible();
    await expect(page.getByText('Your session has ended. Please sign in again.')).toBeVisible();
    await expect(page.getByText('Rep Tester')).toHaveCount(0);

    await openMembers(page, env('E2E_ADMIN_EMAIL'));
    expect(await membersOf(page)).toEqual(before);
  });

  test('the members page fits a narrow screen without scrolling sideways', async ({ page }) => {
    await page.setViewportSize({ width: 320, height: 640 });
    await openMembers(page, env('E2E_ADMIN_EMAIL'));

    const overflow = await page.getByRole('main').evaluate((main) => main.scrollWidth - main.clientWidth);
    expect(overflow).toBeLessThanOrEqual(0);
    // Reached by scrolling down only: fully inside the viewport once scrolled to.
    const remove = page.getByRole('button', { name: 'Remove Rep Tester' });
    await remove.scrollIntoViewIfNeeded();
    await expect(remove).toBeInViewport({ ratio: 1 });
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

  test('the only ADMIN cannot demote or remove themselves', async ({ page }) => {
    await openMembers(page, env('E2E_ADMIN_EMAIL'));
    const before = await membersOf(page);
    expect(before.filter((m) => m.role === 'ADMIN').map((m) => m.displayName)).toEqual(['Admin Tester']);

    await page.getByLabel('New role for Admin Tester').selectOption('REP');
    await expect(page.getByText('This is your own membership.')).toBeVisible();
    await page.getByRole('button', { name: 'Change role of Admin Tester' }).click();

    await expect(page.getByRole('alert')).toContainText('An organization needs at least one admin.');
    await expect(page.getByRole('alert')).toBeFocused();
    await expect(page.getByLabel('New role for Admin Tester')).toHaveValue('ADMIN');
    await expect(page.getByRole('form', { name: 'Add a member' })).toBeVisible();

    await page.getByRole('button', { name: 'Remove Admin Tester' }).click();
    await expect(page.getByText('You are removing yourself')).toBeVisible();
    await page.getByRole('button', { name: 'Yes, remove Admin Tester' }).click();
    await expect(page.getByRole('alert')).toContainText('An organization needs at least one admin.');
    await expect(page).toHaveURL(new RegExp(`/o/${env('E2E_ORG_A')}/members$`));
    await expect(page.getByRole('rowheader', { name: 'Admin Tester (you)' })).toBeVisible();
    expect(await membersOf(page)).toEqual(before);
  });

  test('keyboard only: an ADMIN who is demoted or removed while the page is open is told so; a lost answer is an unknown outcome', async ({
    browser,
    page,
  }) => {
    const org = env('E2E_ORG_A');
    const path = `/api/v1/organizations/${org}/members`;
    await openMembers(page, env('E2E_ADMIN_EMAIL'));
    const before = await membersOf(page);

    // The ADMIN adds Deputy as ADMIN with the keyboard only.
    await page.getByLabel('E-mail address of the user').focus();
    await page.keyboard.type(env('E2E_DEPUTY_EMAIL'));
    await page.keyboard.press('Tab');
    await expect(page.getByLabel('Role', { exact: true })).toBeFocused();
    await page.keyboard.type('ADMIN');
    await expect(page.getByLabel('Role', { exact: true })).toHaveValue('ADMIN');
    await page.keyboard.press('Tab');
    await page.keyboard.press('Enter');
    await expect(page.getByRole('status')).toHaveText(`${env('E2E_DEPUTY_EMAIL')} was added as ADMIN.`);
    await expect(page.getByLabel('E-mail address of the user')).toBeFocused();
    const deputy = (await membersOf(page)).find((m) => m.displayName === 'Deputy Tester');
    expect(deputy).toMatchObject({ role: 'ADMIN' });
    const deputyId = deputy?.membershipId ?? '';

    // Deputy opens the members page in a session of their own.
    const other = await browser.newContext();
    const second = await other.newPage();
    await openMembers(second, env('E2E_DEPUTY_EMAIL'));
    await expect(second.getByRole('form', { name: 'Add a member' })).toBeVisible();

    // The ADMIN makes Deputy a MANAGER, with the keyboard.
    await page.getByLabel('New role for Deputy Tester').focus();
    await page.keyboard.type('MANAGER');
    await page.keyboard.press('Tab');
    await expect(page.getByRole('button', { name: 'Change role of Deputy Tester' })).toBeFocused();
    await page.keyboard.press('Enter');
    const status = page.getByRole('status');
    await expect(status).toHaveText('The role of Deputy Tester is now MANAGER.');
    await expect(status).toBeFocused();

    // Deputy's page still shows the controls of an ADMIN; the next change is refused and the controls go.
    await second.getByLabel('New role for Rep Tester').selectOption('MANAGER');
    await second.getByRole('button', { name: 'Change role of Rep Tester' }).click();
    await expect(second.getByRole('alert')).toHaveText('You do not have permission to do this. The list was reloaded.');
    await expect(second.getByRole('alert')).toBeFocused();
    await expect(second.getByRole('form', { name: 'Add a member' })).toHaveCount(0);
    await expect(second.getByRole('button', { name: /^(Change role of|Remove) / })).toHaveCount(0);
    await expect(second.getByRole('columnheader', { name: 'E-mail address' })).toHaveCount(1);
    expect((await membersOf(page)).find((m) => m.displayName === 'Rep Tester')).toMatchObject({ role: 'REP' });

    // Deputy is ADMIN again and reloads the page.
    const promoted = await page.request.patch(`${path}/${deputyId}`, { headers: await unsafeHeaders(page), data: { role: 'ADMIN' } });
    expect(promoted.status()).toBe(200);
    await second.reload();
    await expect(second.getByRole('form', { name: 'Add a member' })).toBeVisible();

    // The ADMIN removes Deputy with the keyboard. The removal reaches the
    // server, but its answer is lost: the browser's own request is aborted
    // after the same removal has been sent with the ADMIN's session.
    await page.route(`**${path}/${deputyId}`, async (route) => {
      if (route.request().method() !== 'DELETE') {
        await route.continue();
        return;
      }
      const removed = await page.request.delete(`${path}/${deputyId}`, { headers: await unsafeHeaders(page) });
      expect(removed.status()).toBe(204);
      await route.abort('connectionreset');
    });
    await page.getByRole('button', { name: 'Remove Deputy Tester' }).focus();
    await page.keyboard.press('Enter');
    await expect(page.getByRole('button', { name: 'Cancel' })).toBeFocused();
    await page.keyboard.press('Shift+Tab');
    await expect(page.getByRole('button', { name: 'Yes, remove Deputy Tester' })).toBeFocused();
    await page.keyboard.press('Enter');
    const alert = page.getByRole('alert');
    await expect(alert).toContainText('so it is not known whether the change was saved');
    await expect(alert).toBeFocused();
    // The list read again shows what the server has: Deputy is gone.
    await expect(page.getByRole('table')).not.toContainText('Deputy Tester');
    await page.unroute(`**${path}/${deputyId}`);

    // Deputy's next change finds nothing; the page and the start page follow the lost access.
    await second.getByLabel('New role for Rep Tester').selectOption('MANAGER');
    await second.getByRole('button', { name: 'Change role of Rep Tester' }).click();
    await expect(second.getByRole('heading', { name: 'Not found' })).toBeVisible();
    await expect(second.getByRole('navigation', { name: 'Organizations' })).toHaveCount(0);
    await second.getByRole('link', { name: 'Go to the start page' }).click();
    await expect(second.getByText('You are not a member of any organization yet.')).toBeVisible();
    await other.close();

    expect(await membersOf(page)).toEqual(before);
  });
});
