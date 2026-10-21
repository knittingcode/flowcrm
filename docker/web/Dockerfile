# syntax=docker/dockerfile:1
# FlowCRM web: the React + TypeScript SPA with Vite, as the unprivileged node
# user. Targets: dev (Vite dev server; src/, public/ and index.html come from
# the mounts of compose.yaml, so editing them does not rebuild the image) and
# ci (the full source, for tests/app/frontend.sh).
# Build context: the repository root.

ARG NODE_IMAGE=node:24.20.0-alpine3.24@sha256:e67514e5d0f6c46656005e1b693b2ec9d52e80b641307de684d4a015ba7a4eaf

FROM ${NODE_IMAGE} AS deps
# OpenSSL fixes published after the base image (CVE-2026-14456).
RUN apk upgrade --no-cache libssl3 libcrypto3
WORKDIR /app
RUN chown node:node /app
USER node
COPY --chown=node:node frontend/package.json frontend/package-lock.json ./
RUN npm ci --ignore-scripts --no-audit --no-fund

FROM deps AS dev
COPY --chown=node:node frontend/vite.config.ts frontend/tsconfig.json frontend/tsconfig.app.json frontend/tsconfig.node.json ./
EXPOSE 5173
CMD ["node_modules/.bin/vite"]

FROM deps AS ci
COPY --chown=node:node frontend/ ./
