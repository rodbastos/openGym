#!/bin/sh
# Runs supergateway bound to localhost only, with the auth proxy as the public
# listener. See deploy/mcp-auth-proxy.js.
set -e

supergateway \
  --stdio "node /app/mcp/src/index.js" \
  --outputTransport streamableHttp \
  --streamableHttpPath /mcp \
  --host 127.0.0.1 \
  --port 9000 &

exec node /app/deploy/mcp-auth-proxy.js
