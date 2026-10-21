import { defineConfig, devices } from '@playwright/test';

// Runs in the Playwright container on the Compose project's `front` network;
// BASE_URL is the edge (http://edge:8080). No host port is involved.
const baseURL = process.env.BASE_URL;
if (baseURL === undefined || baseURL === '') {
  throw new Error('Set BASE_URL to the edge URL, for example http://edge:8080.');
}

export default defineConfig({
  testDir: './e2e',
  forbidOnly: true,
  retries: 0,
  workers: 1,
  timeout: 30_000,
  reporter: [['list']],
  use: {
    baseURL,
    trace: 'off',
  },
  projects: [{ name: 'chromium', use: { ...devices['Desktop Chrome'] } }],
});
