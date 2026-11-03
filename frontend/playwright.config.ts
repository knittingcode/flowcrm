import { defineConfig, devices } from '@playwright/test';

// Runs in the Playwright container on the Compose project's `front` network;
// BASE_URL is the edge (http://edge:8080). No host port is involved.
const baseURL = process.env.BASE_URL;
if (baseURL === undefined || baseURL === '') {
  throw new Error('Set BASE_URL to the edge URL, for example http://edge:8080.');
}
// HTTPS runs (tests/app/prodlike.sh): the edge's throwaway certificate is
// trusted by its public key only; any other certificate error still fails.
const trustedKey = process.env.HTTPS_SPKI;

export default defineConfig({
  testDir: './e2e',
  // The HTTPS tests need the HTTPS test edge (MODE=https); other runs do not list them.
  testIgnore: process.env.MODE === 'https' ? [] : ['**/https.spec.ts'],
  forbidOnly: true,
  retries: 0,
  workers: 1,
  timeout: 30_000,
  reporter: [['list']],
  use: {
    baseURL,
    trace: 'off',
  },
  projects: [
    {
      name: 'chromium',
      use: {
        ...devices['Desktop Chrome'],
        launchOptions: { args: trustedKey ? [`--ignore-certificate-errors-spki-list=${trustedKey}`] : [] },
      },
    },
  ],
});
