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

Endpoint: `https://mcp-gym.<seu-dominio>/mcp` (Streamable HTTP).
Auth: por usuário — cada `uid` tem sua chave em `./data/mcp-users.json`.

Health: `https://mcp-gym.<seu-dominio>/healthz` → `ok` (aberto por design — só o
`/mcp` exige a chave).

### Dar acesso MCP a um usuário

O uid da pessoa precisa existir primeiro (ela cria o perfil no app). Depois, na
VM:

```bash
./deploy/mcp-user.sh add <uid>   # gera a chave e imprime a URL pronta
./deploy/mcp-user.sh list        # uids e chaves (mascaradas)
./deploy/mcp-user.sh rm <uid>    # revoga
```

Cada chave só lê os dados do próprio uid — o servidor MCP de cada usuário roda
com `OPENGYM_UID` fixo e as tools não aceitam troca de perfil.

> **Nota sobre hostname**: use um subdomínio de *um nível* (`mcp-gym.`).
> O cert Universal SSL do Cloudflare cobre `*.dominio`, mas não
> `mcp.sub.dominio` (segundo nível exige Advanced Certificate Manager).

### Config de cliente (ChatGPT, Claude, Cursor…)

Clientes que aceitam URL + headers:

```json
{
  "mcpServers": {
    "opengym": {
      "url": "https://mcp-gym.<seu-dominio>/mcp",
      "headers": { "Authorization": "Bearer <chave-do-usuario>" }
    }
  }
}
```

Clientes que **não enviam headers** (ex.: conectores do ChatGPT) — a chave vai
na URL:

```
https://mcp-gym.<seu-dominio>/mcp?key=<chave-do-usuario>
```

(o `?key=` é removido antes de chegar ao MCP; ainda assim prefira o Bearer
quando o cliente suportar — URLs aparecem em logs.)

Clientes que só aceitam stdio (Claude Desktop clássico): use o próprio
supergateway como ponte local:

```json
{
  "mcpServers": {
    "opengym": {
      "command": "npx",
      "args": [
        "-y", "supergateway",
        "--streamableHttp", "https://mcp-gym.<seu-dominio>/mcp",
        "--oauth2Bearer", "<chave-do-usuario>"
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
