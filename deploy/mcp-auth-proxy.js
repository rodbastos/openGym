// Bearer-token gate in front of supergateway (deploy/Dockerfile.mcp).
//
// supergateway's --apiKey option is documented on main but not yet in a
// published release, so the gateway itself does no auth — this proxy does.
// It listens on 0.0.0.0:8000 (the port compose/cloudflared reach) and forwards
// to supergateway on 127.0.0.1:9000. /healthz stays open for health checks.

import http from 'node:http'

const KEY = process.env.MCP_API_KEY || ''
const UPSTREAM = 'http://127.0.0.1:9000'

if (!KEY) {
  console.error('[mcp-auth-proxy] MCP_API_KEY is empty — refusing to start unauthenticated')
  process.exit(1)
}

http.createServer((req, res) => {
  if (req.url === '/healthz') {
    res.writeHead(200, { 'content-type': 'text/plain' })
    res.end('ok')
    return
  }

  const bearer = (req.headers.authorization || '').replace(/^Bearer\s+/i, '')
  if (bearer !== KEY && req.headers['x-api-key'] !== KEY) {
    res.writeHead(401, { 'content-type': 'application/json' })
    res.end(JSON.stringify({ error: 'unauthorized' }))
    return
  }

  const headers = { ...req.headers }
  delete headers['x-api-key']

  const upstream = http.request(
    UPSTREAM + req.url,
    { method: req.method, headers },
    (up) => {
      res.writeHead(up.statusCode, up.headers)
      up.pipe(res)
    },
  )
  upstream.on('error', () => {
    if (!res.headersSent) res.writeHead(502)
    res.end('bad gateway')
  })
  req.pipe(upstream)
}).listen(8000, '0.0.0.0', () => {
  console.log('[mcp-auth-proxy] listening on :8000 → ' + UPSTREAM)
})
