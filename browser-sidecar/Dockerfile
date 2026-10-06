# The browser sidecar with its Chromium, for a host that runs each sandbox's
# browser as a container. Built from this directory at the engine's version:
#
#   docker build -t ghcr.io/activeagents/browser-sidecar:1.9.0 browser-sidecar
#
# The start configuration arrives on stdin (`docker run -i`) or from a file
# (`serve --config-file /run/secrets/browser.json`). In a container it would
# typically listen on "host": "0.0.0.0" with a fixed "port", name the
# container's address in "allowed_hosts", and set "chromium_sandbox": false
# unless the runtime grants what Chromium's own sandbox needs.
FROM node:22-bookworm-slim

ENV NODE_ENV=production \
    PLAYWRIGHT_BROWSERS_PATH=/ms-playwright

WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev \
 && npx playwright install --with-deps chromium \
 && rm -rf /root/.npm /var/lib/apt/lists/*

COPY bin ./bin
COPY lib ./lib
COPY README.md LICENSE ./

RUN useradd --create-home --uid 10001 sidecar
USER sidecar

EXPOSE 8931
ENTRYPOINT ["node", "/app/bin/browser-sidecar.mjs"]
CMD ["serve"]
