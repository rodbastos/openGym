// Multi-user MCP gateway for the VM deploy (deploy/Dockerfile.mcp).
//
// Reads /data/mcp-users.json — { "users": [{ "uid": "...", "key": "..." }] } —
// spawns one supergateway per uid (each pinned via OPENGYM_UID, stdio→Streamable
// HTTP on 127.0.0.1:9000+i), and runs a Bearer gate on :8000 that routes each
// request to that key's uid. /healthz stays open.
//
// Keys accepted as Authorization: Bearer, X-API-Key, or ?key= (for clients that
// cannot send headers). To add a user: deploy/mcp-user.sh add <uid>, then
// restart the mcp service.

import http from 'node:http'
import fs from 'node:fs'
import { spawn } from 'node:child_process'

const USERS_FILE = process.env.MCP_USERS_FILE || '/data/mcp-users.json'

let users
try {
  users = JSON.parse(fs.readFileSync(USERS_FILE, 'utf8')).users || []
} catch (e) {
  console.error(`[mcp-server] cannot read ${USERS_FILE}: ${e.message}`)
  process.exit(1)
}
if (!users.length) {
  console.error('[mcp-server] no users in mcp-users.json — refusing to start unauthenticated')
  process.exit(1)
}

// One supergateway per uid, internal ports 9000, 9001, … (array order is stable).
users.forEach((u, i) => {
  u.port = 9000 + i
  const launch = () => {
    const p = spawn('supergateway', [
      '--stdio', 'node /app/mcp/src/index.js',
      '--outputTransport', 'streamableHttp',
      '--streamableHttpPath', '/mcp',
      '--host', '127.0.0.1',
      '--port', String(u.port),
    ], { env: { ...process.env, OPENGYM_UID: u.uid }, stdio: 'inherit' })
    p.on('exit', (code) => {
      console.error(`[mcp-server] gateway for uid ${u.uid} exited (${code}) — restarting in 2s`)
      setTimeout(launch, 2000)
    })
  }
  launch()
  console.log(`[mcp-server] uid ${u.uid} → 127.0.0.1:${u.port}`)
})

const keyOf = (req, url) =>
  (req.headers.authorization || '').replace(/^Bearer\s+/i, '') ||
  req.headers['x-api-key'] ||
  url.searchParams.get('key') ||
  ''

http.createServer((req, res) => {
  if (req.url === '/healthz') {
    res.writeHead(200, { 'content-type': 'text/plain' })
    res.end('ok')
    return
  }

  const url = new URL(req.url, 'http://x')
  const user = users.find((u) => u.key === keyOf(req, url))
  if (!user) {
    res.writeHead(401, { 'content-type': 'application/json' })
    res.end(JSON.stringify({ error: 'unauthorized' }))
    return
  }

  url.searchParams.delete('key')
  const headers = { ...req.headers }
  delete headers['x-api-key']

  const upstream = http.request(
    `http://127.0.0.1:${user.port}${url.pathname}${url.search}`,
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
}).listen(8000, () => {
  console.log(`[mcp-server] auth proxy listening on :8000, ${users.length} user(s)`)
})
