# syntax=docker/dockerfile:1
# FlowCRM web: the React + TypeScript SPA with Vite, as the unprivileged node
# user. Targets: dev (Vite dev server; src/, public/ and index.html come from
# the mounts of compose.yaml, so editing them does not rebuild the image) and
# ci (the full source, for tests/app/frontend.sh).
# Build context: the repository root.

ARG NODE_IMAGE=node:24.22.1-alpine3.24@sha256:6a1c190e17215d844926b0677f4bf87273ff7d5e54db06d3b5b5863ab0b09a3d

FROM ${NODE_IMAGE} AS deps
# The npm bundled with Node 24.22.1 (11.19.1) ships modules with known HIGH
# vulnerabilities (docs/security/container-vulnerabilities.md); replace it
# with a pinned release whose tarball is verified against its checksum.
ARG NPM_VERSION=11.21.1
ARG NPM_SHA256=dd77c48eb845f4856c2cdba347cfb52bd877a2655a1ea48ff0c4796e3df9dd7b
RUN wget -q -O /tmp/npm.tgz "https://registry.npmjs.org/npm/-/npm-${NPM_VERSION}.tgz" \
 && echo "${NPM_SHA256}  /tmp/npm.tgz" | sha256sum -c - \
 && npm install -g --no-audit --no-fund /tmp/npm.tgz \
 && rm /tmp/npm.tgz \
 && test "$(npm -v)" = "${NPM_VERSION}"
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
