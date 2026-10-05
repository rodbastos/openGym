#!/usr/bin/env bash
# Manage per-user MCP keys. Run on the VM from the repo root:
#   ./deploy/mcp-user.sh add <uid>     → prints the user's MCP URL
#   ./deploy/mcp-user.sh list
#   ./deploy/mcp-user.sh rm <uid>
# ./data is root-owned (api runs as root) → sudo for writes.
set -euo pipefail
cd "$(dirname "$0")/.."

FILE=data/mcp-users.json
COMPOSE="docker compose -f docker-compose.yml -f docker-compose.vm.yml"
APP_DOMAIN="$(grep -E '^RP_ID=' .env | cut -d= -f2-)"
MCP_HOST="mcp-${APP_DOMAIN%%.*}.$(echo "$APP_DOMAIN" | cut -d. -f2-)"

[ -f "$FILE" ] || echo '{"users":[]}' | sudo tee "$FILE" >/dev/null

case "${1:-}" in
  add)
    uid="${2:?usage: mcp-user.sh add <uid>}"
    key="$(openssl rand -hex 32)"
    sudo python3 - "$FILE" "$uid" "$key" <<'PY'
import json, sys
f, uid, key = sys.argv[1:4]
d = json.load(open(f))
if any(u['uid'] == uid for u in d['users']):
    sys.exit(f'uid {uid} already has a key — use `list` to see it')
d['users'].append({'uid': uid, 'key': key})
json.dump(d, open(f, 'w'), indent=2)
print(key)
PY
    echo "==> MCP URL: https://${MCP_HOST}/mcp?key=${key}"
    echo "==> Restarting mcp…"
    $COMPOSE restart mcp
    ;;
  list)
    sudo python3 -c "import json;[print(u['uid'], u['key'][:8]+'…') for u in json.load(open('$FILE'))['users']]"
    ;;
  rm)
    uid="${2:?usage: mcp-user.sh rm <uid>}"
    sudo python3 - "$FILE" "$uid" <<'PY'
import json, sys
f, uid = sys.argv[1:3]
d = json.load(open(f))
d['users'] = [u for u in d['users'] if u['uid'] != uid]
json.dump(d, open(f, 'w'), indent=2)
PY
    $COMPOSE restart mcp
    ;;
  *)
    echo "usage: $0 {add <uid>|list|rm <uid>}" >&2; exit 1;;
esac
