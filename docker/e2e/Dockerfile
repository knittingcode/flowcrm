# syntax=docker/dockerfile:1.27.1@sha256:4edf897a3ffa55b89f906fc8cc78afdb3f1834cc9c7083565e611a8a7d5fe99e
# Browser smoke tests (Playwright, Chromium) against the edge of a running
# Compose project. The image ships the browsers matching @playwright/test.
# Build context: the repository root.

ARG PLAYWRIGHT_IMAGE=mcr.microsoft.com/playwright:v1.64.1-noble@sha256:7852dc5a7d72f5fe458a597d690f6c42fbc8e9e26ddfa95f8e6ef552558d9bbf

FROM ${PLAYWRIGHT_IMAGE}
WORKDIR /e2e
RUN chown pwuser:pwuser /e2e
USER pwuser
COPY --chown=pwuser:pwuser frontend/package.json frontend/package-lock.json ./
RUN npm ci --ignore-scripts --no-audit --no-fund
COPY --chown=pwuser:pwuser frontend/playwright.config.ts ./
COPY --chown=pwuser:pwuser frontend/e2e ./e2e
ENTRYPOINT ["npx", "playwright", "test"]
