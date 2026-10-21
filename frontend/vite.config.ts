/// <reference types="vitest/config" />
import react from '@vitejs/plugin-react';
import { defineConfig } from 'vite';

// The dev server runs inside the `web` container and is reached only through
// the Caddy edge; port 5173 is never published to the host.
export default defineConfig({
  plugins: [react()],
  server: {
    host: '0.0.0.0',
    port: 5173,
    strictPort: true,
    // Requests arrive through Caddy with the browser's Host (an IP address,
    // allowed by default) or, for the in-network browser tests, as `edge`.
    allowedHosts: ['edge'],
  },
  build: {
    sourcemap: false,
  },
  test: {
    environment: 'jsdom',
    setupFiles: ['./src/test/setup.ts'],
    include: ['src/**/*.test.{ts,tsx}'],
    restoreMocks: true,
  },
});
