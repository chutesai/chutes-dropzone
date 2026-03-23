# chutes-dropzone

Self-hosted Chutes workspace with:

- a public landing page at `/`
- OpenWebUI at `/chat/`
- n8n at `/n8n/`
- native Chutes SSO for both apps
- one shared Postgres instance
- optional shared `e2ee-proxy` routing for OpenAI-compatible traffic

`chutes-dropzone` keeps the same local-vs-domain deployment model as `chutes-n8n-local`, but turns it into a single-host AI workspace instead of a single-app install.

## Quick Start

### Repo-Based Deploy

```bash
git clone https://github.com/chutesai/chutes-dropzone.git
cd chutes-dropzone
./deploy.sh
```

Interactive deploy asks for:

- `INSTALL_MODE`: `local` or `domain`
- `CHUTES_TRAFFIC_MODE`: `direct` or `e2ee-proxy`
- `OPENWEBUI_API_KEY`: optional; leave empty for public Chutes model endpoints
- `OPENWEBUI_MODELS_CACHE_TTL`: model-list cache TTL for OpenWebUI, default `300`
- `OPENWEBUI_MODEL_ORDER_SYNC_INTERVAL`: background model-order refresh interval, default `300`
- `CHUTES_API_KEY`: optional n8n credential import key
- Chutes OAuth client ID and secret
- `DROPZONE_HOST` and `ACME_EMAIL` for domain installs

After deploy:

- `https://<host>/` is the landing page
- `https://<host>/chat/` opens OpenWebUI
- `https://<host>/n8n/` opens n8n

### Required Chutes OAuth Callbacks

Register both exact redirect URIs on the same Chutes OAuth app:

- `https://<host>/oauth/oidc/callback`
- `https://<host>/rest/sso/chutes/callback`

Recommended scopes:

- `openid`
- `profile`
- `chutes:read`
- `chutes:invoke`

## Routing Model

The public topology is fixed in v1:

- `/` serves a dark Chutes-branded landing page
- `/chat/` is the human-friendly OpenWebUI entrypoint and redirects into OpenWebUI's native home route
- `/n8n/` reverse-proxies to n8n without stripping the prefix
- `/v1/*` is exposed only when `CHUTES_TRAFFIC_MODE=e2ee-proxy`

Local installs intentionally stay on a single exact-cert host instead of subdomains.

## Modes

### Install Mode

- `local`: uses `https://e2ee-local-proxy.chutes.dev`
- `domain`: uses your real `DROPZONE_HOST` and Caddy/ACME

### Traffic Mode

- `direct`: OpenWebUI and n8n use native Chutes endpoints
- `e2ee-proxy`: OpenAI-compatible LLM traffic uses the shared `/v1/*` proxy path

## Key Env Vars

See [.env.example](./.env.example) for the full set. The main public/operator-facing vars are:

- `DROPZONE_HOST`
- `POSTGRES_N8N_DB`
- `POSTGRES_OPENWEBUI_DB`
- `OPENWEBUI_VERSION`
- `OPENWEBUI_ADMIN_EMAIL`
- `OPENWEBUI_ADMIN_PASSWORD`
- `WEBUI_SECRET_KEY`

Compatibility aliases still exist:

- `N8N_HOST` mirrors `DROPZONE_HOST`
- `POSTGRES_DB` falls back to `POSTGRES_N8N_DB`

## OpenWebUI Runtime

OpenWebUI is kept env-authoritative:

- `WEBUI_URL=https://<host>/chat`
- `OPENID_REDIRECT_URI=https://<host>/oauth/oidc/callback`
- `ENABLE_PERSISTENT_CONFIG=false`
- `ENABLE_OAUTH_PERSISTENT_CONFIG=false`
- `ENABLE_OAUTH_SIGNUP=true`
- `DEFAULT_USER_ROLE=user`
- `BYPASS_MODEL_ACCESS_CONTROL=true`
- `ENABLE_OAUTH_EMAIL_FALLBACK=true`
- `ENABLE_LOGIN_FORM=false`
- `ENABLE_PASSWORD_AUTH=false`
- `OAUTH_USERNAME_CLAIM=username`

At startup, Dropzone also seeds OpenWebUI runtime config so model backends use the signed-in Chutes OAuth token (`system_oauth`) for completions, while the global model picker is ordered TEE-first, grouped by provider/lab, and then sorted newest-first within each lab using model version and dated release hints from the Chutes model IDs.

Dropzone keeps that ordering fresh in the background with a server-side sync worker. By default, OpenWebUI refreshes its upstream model cache every 5 minutes and the worker reseeds `MODEL_ORDER_LIST` on the same cadence, so newly published Chutes models settle into the intended order without a redeploy.

Chutes currently does not advertise an `email` scope or `email` claim in the live OIDC discovery document, so OpenWebUI uses its synthetic-email fallback for user creation.

Deploy also auto-promotes any existing OAuth-created OpenWebUI users stuck in `pending` to `user`, so earlier failed SSO attempts recover cleanly after a redeploy.

Normal runtime is SSO-only. A local admin account is still seeded as break-glass recovery.

## Break-Glass Recovery

n8n and OpenWebUI both get generated local admin credentials during deploy.

For OpenWebUI, normal runtime keeps password login disabled. To recover access temporarily, edit `.env`, set:

```bash
ENABLE_OAUTH_SIGNUP=false
ENABLE_LOGIN_FORM=true
ENABLE_PASSWORD_AUTH=true
```

then restart the stack, use the seeded OpenWebUI admin account, and revert those values afterward.

## Standalone Image

`Dockerfile.local-repo` packages:

- n8n
- OpenWebUI
- OpenResty
- Caddy
- the landing page
- bundled `n8n-nodes-chutes`
- starter workflows

Build locally:

```bash
docker buildx build --load \
  -t chutes-dropzone:local-repo \
  -f Dockerfile.local-repo .
```

Run interactively:

```bash
docker run --rm -it \
  -p 80:80 -p 443:443 \
  chutes-dropzone:local-repo
```

Persistent standalone state lives under `/data`:

- `/data/.n8n`
- `/data/openwebui`
- `/data/caddy`
- `/data/.env`

## Verification

```bash
./scripts/smoke-test.sh --syntax
./scripts/smoke-test.sh
./scripts/e2e-test.sh
```

The smoke and e2e coverage now validate:

- landing page reachability at `/`
- OpenWebUI reachability at `/chat/`
- n8n reachability at `/n8n/`
- native n8n SSO flow
- the fake Chutes IdP OIDC surface used by OpenWebUI
- local proxy `/v1/*` behavior in proxy mode
