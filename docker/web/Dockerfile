# syntax=docker/dockerfile:1
# FlowCRM web: the React + TypeScript SPA with Vite, as the unprivileged node
# user. Targets: dev (Vite dev server; source mounted by compose.yaml) and
# check (type check, lint, unit tests and production build).
# Build context: the repository root.

ARG NODE_IMAGE=node:24.20.0-alpine3.24@sha256:e67514e5d0f6c46656005e1b693b2ec9d52e80b641307de684d4a015ba7a4eaf

FROM ${NODE_IMAGE} AS deps
WORKDIR /app
RUN chown node:node /app
USER node
COPY --chown=node:node frontend/package.json frontend/package-lock.json ./
RUN npm ci --ignore-scripts --no-audit --no-fund

FROM deps AS dev
COPY --chown=node:node frontend/ ./
EXPOSE 5173
CMD ["node_modules/.bin/vite"]

FROM deps AS check
COPY --chown=node:node frontend/ ./
RUN npm run typecheck && npm run lint && npm test && npm run build
