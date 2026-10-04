#!/usr/bin/env bash
# openGym VM bootstrap — Debian 12 (GCP e2-micro free tier).
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/rodbastos/openGym/main/deploy/vm-setup.sh | bash -s -- <app-host>
# or, from a clone:
#   APP_HOST=opengym.example.com bash deploy/vm-setup.sh
#
# What it does:
#   1. Installs Docker Engine + compose plugin (official Debian repo)
#   2. Clones the fork into ~/openGym
#   3. Writes .env (RP_ID/ORIGIN from APP_HOST, generated MCP_API_KEY if unset)
#   4. Pulls the prebuilt images, builds the MCP bridge, starts the stack
#
# Prompts for anything missing. Re-runnable: skips work already done.

set -euo pipefail

REPO="${OPENGYM_REPO:-https://github.com/rodbastos/openGym}"
DIR="${OPENGYM_DIR:-$HOME/openGym}"
APP_HOST="${1:-${APP_HOST:-}}"

echo "==> openGym VM setup (repo: $REPO)"

# ── 1. Docker ───────────────────────────────────────────────────────────────
if ! command -v docker >/dev/null 2>&1; then
  echo "==> Installing Docker…"
  sudo apt-get update
  sudo apt-get install -y ca-certificates curl git gnupg
  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg \
    | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  sudo chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  sudo apt-get update
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin
  sudo usermod -aG docker "$USER"
  echo "!! Added $USER to the docker group — run 'newgrp docker' or reconnect,"
  echo "!! then re-run this script."
  exit 0
fi
docker compose version >/dev/null 2>&1 || { echo "docker compose plugin missing"; exit 1; }

# ── 2. Clone ────────────────────────────────────────────────────────────────
if [ ! -d "$DIR/.git" ]; then
  echo "==> Cloning $REPO → $DIR"
  git clone "$REPO" "$DIR"
fi
cd "$DIR"

# ── 3. .env ─────────────────────────────────────────────────────────────────
if [ ! -f .env ]; then
  cp deploy/.env.vm.example .env
  echo "==> Created .env from deploy/.env.vm.example"
fi

ask() { # ask VAR "prompt" — skip if already non-empty in .env or env
  local var="$1" prompt="$2" current
  current="$(grep -E "^${var}=" .env | cut -d= -f2- || true)"
  [ -n "$current" ] && return 0
  read -rp "$prompt: " current
  sed -i "s|^${var}=.*|${var}=${current}|" .env
}

# App host → RP_ID + ORIGIN (both derive from the same hostname).
if [ -z "$APP_HOST" ]; then
  current_rp="$(grep -E '^RP_ID=' .env | cut -d= -f2- || true)"
  if [ -z "$current_rp" ] || [ "$current_rp" = "opengym.example.com" ]; then
    read -rp "Public app hostname (e.g. opengym.example.com): " APP_HOST
  else
    APP_HOST="$current_rp"
  fi
fi
sed -i "s|^RP_ID=.*|RP_ID=${APP_HOST}|; s|^ORIGIN=.*|ORIGIN=https://${APP_HOST}|" .env

# MCP_API_KEY — generate if unset.
if ! grep -qE '^MCP_API_KEY=.+' .env; then
  MCP_API_KEY="$(openssl rand -hex 32)"
  sed -i "s|^MCP_API_KEY=.*|MCP_API_KEY=${MCP_API_KEY}|" .env
  echo "==> Generated MCP_API_KEY (saved in .env)"
fi

# TUNNEL_TOKEN — must come from the Cloudflare dashboard.
if ! grep -qE '^TUNNEL_TOKEN=.+' .env; then
  echo "    Create the tunnel first: Cloudflare Zero Trust → Networks → Tunnels."
  ask TUNNEL_TOKEN "TUNNEL_TOKEN"
fi

# ── 4. Up ───────────────────────────────────────────────────────────────────
COMPOSE="docker compose -f docker-compose.yml -f docker-compose.vm.yml"

echo "==> Pulling prebuilt images…"
$COMPOSE pull media api web cloudflared

echo "==> Building the MCP bridge…"
$COMPOSE build mcp

echo "==> Starting…"
$COMPOSE up -d

echo
echo "==> Done. Status:"
$COMPOSE ps
echo
echo "Next: https://${APP_HOST} — create your profile + passkey."
echo "MCP endpoint: https://mcp.<your-domain>/mcp  (Authorization: Bearer \$MCP_API_KEY)"
