# chutes-dropzone

Self-hosted Chutes workspace with:

- an optional public landing page at `/`
- OpenWebUI at `/chat/`
- n8n at `/n8n/`
- native Chutes SSO for both apps
- Chutes quota/tier/account chrome inside both apps
- one shared Postgres instance
- optional shared `e2ee-proxy` routing for OpenAI-compatible traffic

`chutes-dropzone` keeps the same local-vs-domain deployment model as `chutes-n8n-local`, but turns it into a single-host AI workspace instead of a single-app install.

This repo supports two packaging shapes:

- a single-container standalone image built from `Dockerfile.local-repo`
- a Docker Compose deployment driven by `deploy.sh`

## Quick Start

### Docker

```bash
docker run --rm -it \
  --pull always \
  --platform linux/amd64 \
  -p 443:443 \
  ghcr.io/chutesai/chutes-dropzone:latest
```

See [Standalone Image](#standalone-image) for non-interactive runs, domain mode, runtime flags, persisted state layout, and building from source.

### Kubernetes

For Kubernetes, the easiest supported path is the standalone image with:

- `INSTALL_MODE=domain`
- `CHUTES_TRAFFIC_MODE=direct`
- one persistent volume mounted at `/data`
- a `LoadBalancer` service exposing ports `80` and `443`

That lets the image keep its built-in Caddy/ACME flow for your real hostname instead of trying to split TLS ownership between the cluster ingress and the container.

The example manifest is intentionally cluster-neutral, so the same YAML can work on:

- standard Kubernetes clusters with a real `LoadBalancer` implementation
- MicroK8s with `hostpath-storage` and `metallb` enabled

Example manifest:

- [examples/kubernetes/standalone-domain-direct.yaml](./examples/kubernetes/standalone-domain-direct.yaml)

Typical flow:

1. Replace the placeholder secrets and host values in that manifest.
   The example defaults to `chat.chutes.ai` with `DROPZONE_ENABLE_PUBLIC_LANDING=false`, so `/` redirects straight to `/chat/`.
   Also replace `ghcr.io/chutesai/chutes-dropzone:<release-tag>` with the release tag you want to pin.
2. Apply it: `kubectl apply -f examples/kubernetes/standalone-domain-direct.yaml`
3. Point your DNS `A`/`AAAA` record for `DROPZONE_HOST` at the service's external IP or hostname.
4. Wait for Caddy inside the pod to complete ACME issuance.

Important notes:

- Keep this as a single replica. The standalone image stores state under `/data`.
- For the cleanest setup, expose the service directly with `LoadBalancer`. That is simpler than putting this image behind an ingress, because the image already owns HTTPS termination and ACME in `domain` mode.
- In `direct` mode, OpenWebUI talks to `https://llm.chutes.ai/v1`, and n8n uses its native direct Chutes resolution path.
- If you want proxy-mode or multi-pod patterns later, that is a different deployment shape than this simplest standalone example.

MicroK8s notes:

- Enable storage: `microk8s enable hostpath-storage`
- Enable a load balancer IP pool: `microk8s enable metallb:<start-ip>-<end-ip>`
- Then apply the same manifest and point DNS at the assigned external IP

### Repo-Based

macOS/Linux/WSL:

```bash
bash <(curl -fsSL -H 'Cache-Control: no-cache' \
  "https://raw.githubusercontent.com/chutesai/chutes-dropzone/main/deploy.sh?$(date +%s)")
```

The deploy script:

- clones or refreshes `chutesai/chutes-dropzone`
- runs `deploy.sh`
- auto-clones `sirouk/n8n-nodes-chutes` beside it if missing
- resets `n8n-nodes-chutes` to the checked-in pinned commit on clean reruns so local builds match CI and release images

When launched from a terminal, the deploy script prompts for install mode and the required Chutes OAuth settings even when invoked via `curl ... | bash`.

For headless or CI usage, preseed the required environment variables:

```bash
curl -fsSL https://raw.githubusercontent.com/chutesai/chutes-dropzone/main/deploy.sh | \
  INSTALL_MODE=local \
  CHUTES_OAUTH_CLIENT_ID=... \
  CHUTES_OAUTH_CLIENT_SECRET=... \
  bash
```

Manual clone:

```bash
git clone https://github.com/chutesai/chutes-dropzone.git
cd chutes-dropzone
./deploy.sh
```

If `../n8n-nodes-chutes` is missing, deploy will clone:

```text
https://github.com/sirouk/n8n-nodes-chutes.git
```

You can override that source if needed with:

```bash
CHUTES_N8N_NODES_GIT_URL=git@github.com:sirouk/n8n-nodes-chutes.git ./deploy.sh
```

You can also temporarily test a different branch or commit without changing the checked-in pin:

```bash
CHUTES_N8N_NODES_GIT_REF=<branch-or-commit> ./deploy.sh
```

Advanced CI/testing runs can also point deploy at prebuilt local app images and skip the heavy app rebuild:

```bash
DROPZONE_N8N_IMAGE=chutes-dropzone-n8n:local \
DROPZONE_OPENWEBUI_IMAGE=chutes-dropzone-openwebui:local \
SKIP_APP_BUILDS=true \
./deploy.sh --force
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

- `https://<host>/` is either the landing page or a redirect to `/chat/`, depending on `DROPZONE_ENABLE_PUBLIC_LANDING`
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

- `/` either serves a dark Chutes-branded landing page or redirects to `/chat/`
- `/chat/` is the human-friendly OpenWebUI entrypoint and redirects into OpenWebUI's native home route
- `/n8n/` reverse-proxies to n8n without stripping the prefix
- `/v1/*` is exposed only when `CHUTES_TRAFFIC_MODE=e2ee-proxy`

`DROPZONE_ENABLE_PUBLIC_LANDING=true` preserves the launcher at `/`.

`DROPZONE_ENABLE_PUBLIC_LANDING=false` makes `/` return a redirect to `/chat/`, which is the recommended standalone domain deployment shape for `chat.chutes.ai`.

Local installs intentionally stay on a single exact-cert host instead of subdomains.

## Modes

### Install Mode

- `local`: uses `https://e2ee-local-proxy.chutes.dev`
- `domain`: uses your real `DROPZONE_HOST` and Caddy/ACME

### Traffic Mode

- `direct`: OpenWebUI and n8n use native Chutes endpoints
- `e2ee-proxy`: OpenWebUI and n8n send OpenAI-compatible LLM traffic to the shared
  `e2ee-proxy` sidecar, while the public `/v1/*` edge path simply forwards into that
  same sidecar. n8n SSO text traffic stays on-proxy, and strict TEE-only model catalogs
  are enabled by default

## Key Env Vars

See [.env.example](./.env.example) for the full set. The main public/operator-facing vars are:

- `DROPZONE_HOST`
- `DROPZONE_ENABLE_PUBLIC_LANDING`
- `POSTGRES_N8N_DB`
- `POSTGRES_OPENWEBUI_DB`
- `OPENWEBUI_VERSION`
- `OPENWEBUI_IMAGE`
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

When `CHUTES_TRAFFIC_MODE=direct`, OpenWebUI talks straight to `https://llm.chutes.ai/v1` and n8n resolves text traffic against the native Chutes LLM endpoints.

When `CHUTES_TRAFFIC_MODE=e2ee-proxy`, both OpenWebUI and n8n send invocation traffic through the shared `e2ee-proxy` sidecar. The sidecar's `/v1/models` catalog still sources model metadata anonymously from `https://llm.chutes.ai/v1/models`, then applies local TEE-only filtering when `ALLOW_NON_CONFIDENTIAL=false`.

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

Published image:

- `ghcr.io/chutesai/chutes-dropzone:latest`
- release tags are also published as semver tags when releases are cut

Releases are published for `linux/amd64`.

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

## Releases

`release.sh` is the interactive helper for cutting a GitHub release that drives the published GHCR image.

```bash
./release.sh --dry-run
./release.sh --version v0.1.0
./release.sh --yes
```

It:

- proposes the next patch version from existing tags
- prints the pinned refs and image inputs used by CI and release builds
- verifies the checked-in n8n, OpenWebUI, caddy, and e2ee-proxy pins before publishing
- requires a clean worktree before publishing
- uses `gh` to create the GitHub release that triggers `.github/workflows/release.yml`

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
- GitHub Actions runs the destructive local E2E suite in both `direct` and `e2ee-proxy` traffic modes
