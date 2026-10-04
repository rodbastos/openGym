# Deploy: GCP free tier + Cloudflare Tunnel

Deploy do openGym numa VM `e2-micro` do Google Cloud (free tier) com o app e o
servidor MCP expostos via Cloudflare Tunnel — nenhuma porta inbound aberta na VM.

## Arquitetura

```
internet ──HTTPS──> Cloudflare ──tunnel (só saída)──> cloudflared ─┬─> http://web:80   app (opengym.<dominio>)
                                                                   └─> http://mcp:8000  MCP  (mcp.<dominio>/mcp)
```

- `web` + `api` + `media`: imagens pré-buildadas do GHCR (sem build na VM de 1GB).
- `mcp`: bridge stdio→Streamable HTTP via supergateway (build local, leve), protegido por Bearer token. Read-only sobre `./data`.
- `cloudflared`: conector do named tunnel.

## Pré-requisitos

- Projeto GCP com billing habilitado (free tier exige conta de billing).
- Domínio no Cloudflare.
- `gcloud` CLI autenticado.

## Passo a passo

### 1. Criar a VM (uma vez)

```bash
gcloud compute instances create opengym-vm \
  --zone=us-east1-b --machine-type=e2-micro \
  --image-family=debian-12 --image-project=debian-cloud \
  --boot-disk-size=30GB --boot-disk-type=pd-standard
```

### 2. Criar o túnel no Cloudflare

Dashboard **Zero Trust → Networks → Tunnels → Add a tunnel** (cloudflared):

1. Nomeie (ex.: `opengym`), copie o **token** do conector.
2. Em *Public Hostnames*, crie:
   | Hostname                 | Service          |
   |--------------------------|------------------|
   | `opengym.<seu-dominio>`  | `http://web:80`  |
   | `mcp.<seu-dominio>`      | `http://mcp:8000`|

   (os containers se enxergam pelo nome na rede do compose)

### 3. Subir a stack na VM

```bash
gcloud compute ssh opengym-vm --zone=us-east1-b
APP_HOST=opengym.<seu-dominio> bash deploy/vm-setup.sh
# o script pede o TUNNEL_TOKEN e gera o MCP_API_KEY
```

Ou copie `deploy/.env.vm.example` para `.env`, preencha e rode:

```bash
docker compose -f docker-compose.yml -f docker-compose.vm.yml pull media api web cloudflared
docker compose -f docker-compose.yml -f docker-compose.vm.yml build mcp
docker compose -f docker-compose.yml -f docker-compose.vm.yml up -d
```

### 4. Primeiro acesso

Abra `https://opengym.<seu-dominio>` → **Create profile** → registre a passkey.
Depois, em `./data/db.json`, pegue seu `users[].id` e configure `ADMIN_UIDS` +
`INVITE_ONLY=1` no `.env` (recomendado para instância pública).

## Servidor MCP

Endpoint: `https://mcp.<seu-dominio>/mcp` (Streamable HTTP).
Auth: `Authorization: Bearer <MCP_API_KEY do .env>`.

Health: `https://mcp.<seu-dominio>/healthz` → `ok` (não exige chave? — verifique).

### Config de cliente (Claude Desktop, Cursor…)

Clientes que aceitam servidores MCP remotos:

```json
{
  "mcpServers": {
    "opengym": {
      "url": "https://mcp.<seu-dominio>/mcp",
      "headers": { "Authorization": "Bearer <MCP_API_KEY>" }
    }
  }
}
```

Clientes que só aceitam stdio (Claude Desktop clássico): use o próprio
supergateway como ponte local:

```json
{
  "mcpServers": {
    "opengym": {
      "command": "npx",
      "args": [
        "-y", "supergateway",
        "--streamableHttp", "https://mcp.<seu-dominio>/mcp",
        "--oauth2Bearer", "<MCP_API_KEY>"
      ]
    }
  }
}
```

## Operação

```bash
# logs
docker compose -f docker-compose.yml -f docker-compose.vm.yml logs -f web
docker compose -f docker-compose.yml -f docker-compose.vm.yml logs -f mcp

# backup — um arquivo só com tudo (users, passkeys, treinos)
tar czf opengym-backup-$(date +%F).tar.gz data/

# update do app
git pull
docker compose -f docker-compose.yml -f docker-compose.vm.yml pull media api web cloudflared
docker compose -f docker-compose.yml -f docker-compose.vm.yml up -d
```

## Custos / free tier

- `e2-micro` em `us-east1` + 30GB `pd-standard`: dentro do always-free.
- Egress: 1GB/mo grátis (uso pessoal ok; a mídia de exercícios ~140MB é servida
  sob demanda e cacheada pelo Cloudflare).
- Túnel Cloudflare: grátis.
