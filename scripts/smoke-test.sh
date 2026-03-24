#!/usr/bin/env bash
#
# Smoke tests for chutes-n8n-local.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

compose() {
    local files="${CHUTES_COMPOSE_FILES:-$PROJECT_DIR/docker-compose.yml}"
    local file
    local old_ifs="$IFS"
    local -a args=()

    IFS=':' read -r -a compose_files <<< "$files"
    IFS="$old_ifs"

    for file in "${compose_files[@]}"; do
        if [[ "$file" != /* ]]; then
            file="$PROJECT_DIR/$file"
        fi
        args+=(-f "$file")
    done

    docker compose "${args[@]}" "$@"
}

PASS=0
FAIL=0
SKIP=0
SYNTAX_ONLY=false
EDGE_SERVICE="${EDGE_SERVICE:-}"

for arg in "$@"; do
    [ "$arg" = "--syntax" ] && SYNTAX_ONLY=true
done

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }
skip() { echo "  SKIP: $*"; SKIP=$((SKIP + 1)); }

json_query() {
    local expression="$1"
    if command -v jq >/dev/null 2>&1; then
        jq -r "$expression"
    else
        python3 - "$expression" <<'PY'
import json
import sys

expr = sys.argv[1]
data = json.load(sys.stdin)
value = data
for part in expr.split('.'):
    if not part:
        continue
    value = value.get(part)
print("" if value is None else value)
PY
    fi
}

container_health_status() {
    if [ -z "${1:-}" ]; then
        echo missing
        return
    fi

    docker inspect "$1" --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' 2>/dev/null || echo missing
}

compose_container_id() {
    compose ps -q "$1" 2>/dev/null | head -n 1
}

wait_for_service() {
    local service="$1"
    local attempts="$2"
    local status="missing"
    local container=""

    while [ "$attempts" -gt 0 ]; do
        container="$(compose_container_id "$service")"
        status="$(container_health_status "$container")"
        if [ "$status" = "healthy" ] || [ "$status" = "running" ]; then
            printf '%s' "$status"
            return 0
        fi
        attempts=$((attempts - 1))
        sleep 1
    done

    printf '%s' "$status"
    return 1
}

curl_edge() {
    local -a host_args=()

    if [ "${INSTALL_MODE:-}" = "local" ]; then
        host_args+=(--resolve "${DROPZONE_HOST}:443:127.0.0.1")
        host_args+=(--resolve "${DROPZONE_HOST}:80:127.0.0.1")
    fi

    curl "${host_args[@]}" "$@"
}

echo "=== Syntax checks ==="

for file in "$PROJECT_DIR/deploy.sh" "$PROJECT_DIR/scripts/"*.sh; do
    if bash -n "$file" >/dev/null 2>&1; then
        pass "bash -n $(basename "$file")"
    else
        fail "bash -n $(basename "$file")"
    fi
done

if command -v shellcheck >/dev/null 2>&1; then
    if shellcheck -x "$PROJECT_DIR/deploy.sh" "$PROJECT_DIR/scripts/"*.sh 2>&1; then
        pass "shellcheck shell scripts"
    else
        fail "shellcheck shell scripts"
    fi
else
    skip "shellcheck not installed - skipping shell lint"
fi

if command -v node >/dev/null 2>&1; then
    if node --check "$PROJECT_DIR/scripts/apply-n8n-overlay.mjs" >/dev/null 2>&1; then
        pass "node --check apply-n8n-overlay.mjs"
    else
        fail "node --check apply-n8n-overlay.mjs"
    fi

    if node --check "$PROJECT_DIR/scripts/patch-n8n-nodes-chutes.mjs" >/dev/null 2>&1; then
        pass "node --check patch-n8n-nodes-chutes.mjs"
    else
        fail "node --check patch-n8n-nodes-chutes.mjs"
    fi
else
    skip "node not installed - cannot validate overlay patcher"
fi

if command -v node >/dev/null 2>&1; then
    if node --check "$PROJECT_DIR/landing/app.js" >/dev/null 2>&1; then
        pass "node --check landing/app.js"
    else
        fail "node --check landing/app.js"
    fi

    if node --check "$PROJECT_DIR/branding/openwebui/loader.js" >/dev/null 2>&1; then
        pass "node --check branding/openwebui/loader.js"
    else
        fail "node --check branding/openwebui/loader.js"
    fi

    if node --check "$PROJECT_DIR/branding/n8n/custom.js" >/dev/null 2>&1; then
        pass "node --check branding/n8n/custom.js"
    else
        fail "node --check branding/n8n/custom.js"
    fi
fi

if command -v python3 >/dev/null 2>&1; then
    if python3 -m py_compile "$PROJECT_DIR/scripts/openwebui-model-order-sync.py" >/dev/null 2>&1; then
        pass "python3 -m py_compile openwebui-model-order-sync.py"
    else
        fail "python3 -m py_compile openwebui-model-order-sync.py"
    fi

    if python3 -m py_compile "$PROJECT_DIR/scripts/patch-openwebui-runtime.py" >/dev/null 2>&1; then
        pass "python3 -m py_compile patch-openwebui-runtime.py"
    else
        fail "python3 -m py_compile patch-openwebui-runtime.py"
    fi

    if python3 -m py_compile "$PROJECT_DIR/branding/openwebui/dropzone_account.py" >/dev/null 2>&1; then
        pass "python3 -m py_compile branding/openwebui/dropzone_account.py"
    else
        fail "python3 -m py_compile branding/openwebui/dropzone_account.py"
    fi
else
    skip "python3 not installed - cannot validate OpenWebUI model-order sync helper"
fi

if command -v jq >/dev/null 2>&1; then
    for file in "$PROJECT_DIR/workflows/"*.json; do
        if jq empty "$file" >/dev/null 2>&1; then
            pass "jq $(basename "$file")"
        else
            fail "jq $(basename "$file")"
        fi
    done
else
    skip "jq not installed - cannot validate workflow JSON"
fi

if docker compose -f "$PROJECT_DIR/docker-compose.yml" -f "$PROJECT_DIR/docker-compose.domain.yml" config -q >/dev/null 2>&1; then
    pass "docker compose config (domain stack)"
else
    fail "docker compose config (domain stack)"
fi

if docker compose -f "$PROJECT_DIR/docker-compose.yml" -f "$PROJECT_DIR/docker-compose.local.yml" config -q >/dev/null 2>&1; then
    pass "docker compose config (local stack)"
else
    fail "docker compose config (local stack)"
fi

if docker compose -f "$PROJECT_DIR/docker-compose.yml" -f "$PROJECT_DIR/docker-compose.domain.yml" -f "$PROJECT_DIR/docker-compose.traffic-proxy.yml" config -q >/dev/null 2>&1; then
    pass "docker compose config (domain proxy stack)"
else
    fail "docker compose config (domain proxy stack)"
fi

if docker compose -f "$PROJECT_DIR/docker-compose.yml" -f "$PROJECT_DIR/docker-compose.local.yml" -f "$PROJECT_DIR/docker-compose.test.yml" -f "$PROJECT_DIR/docker-compose.traffic-proxy.yml" config -q >/dev/null 2>&1; then
    pass "docker compose config (local test proxy stack)"
else
    fail "docker compose config (local test proxy stack)"
fi

direct_openwebui_config="$(
    CHUTES_TRAFFIC_MODE=direct \
    OPENWEBUI_API_BASE_URL="https://llm.chutes.ai/v1" \
    docker compose -f "$PROJECT_DIR/docker-compose.yml" -f "$PROJECT_DIR/docker-compose.local.yml" config 2>/dev/null || true
)"
if printf '%s\n' "$direct_openwebui_config" | grep -q 'OPENAI_API_BASE_URLS: https://llm.chutes.ai/v1'; then
    pass "direct mode renders OpenWebUI against llm.chutes.ai"
else
    fail "direct mode did not render OpenWebUI against llm.chutes.ai"
fi

proxy_openwebui_config="$(
    CHUTES_TRAFFIC_MODE=e2ee-proxy \
    OPENWEBUI_API_BASE_URL="https://llm.chutes.ai/v1" \
    docker compose -f "$PROJECT_DIR/docker-compose.yml" -f "$PROJECT_DIR/docker-compose.local.yml" -f "$PROJECT_DIR/docker-compose.traffic-proxy.yml" config 2>/dev/null || true
)"
if printf '%s\n' "$proxy_openwebui_config" | grep -q 'OPENAI_API_BASE_URLS: http://e2ee-proxy:80/v1'; then
    pass "e2ee-proxy mode renders OpenWebUI against the sidecar"
else
    fail "e2ee-proxy mode did not render OpenWebUI against the sidecar"
fi

if printf '%s\n' "$proxy_openwebui_config" | grep -q 'CHUTES_PROXY_BASE_URL: http://e2ee-proxy:80'; then
    pass "e2ee-proxy mode renders n8n against the sidecar"
else
    fail "e2ee-proxy mode did not render n8n against the sidecar"
fi

for placeholder in __SERVER_NAME__ __TLS_DIRECTIVE__ __CHUTES_V1_BLOCK__ __ROOT_ENTRY_BLOCK__; do
    if grep -q "$placeholder" "$PROJECT_DIR/conf/Caddyfile.template"; then
        pass "Caddy template has $placeholder"
    else
        fail "Caddy template missing $placeholder"
    fi
done

for placeholder in __SERVER_NAME__ __RESOLVERS__ __CHUTES_V1_BLOCK__ __ROOT_ENTRY_BLOCK__; do
    if grep -q "$placeholder" "$PROJECT_DIR/conf/local-proxy.nginx.template"; then
        pass "local proxy template has $placeholder"
    else
        fail "local proxy template missing $placeholder"
    fi
done

# shellcheck disable=SC2016
if grep -q 'set \$chutes_v1_host e2ee-proxy;' "$PROJECT_DIR/deploy.sh" && \
   grep -q 'proxy_pass \$chutes_v1_upstream;' "$PROJECT_DIR/deploy.sh"; then
    pass "local proxy defers e2ee-proxy DNS lookup until request time"
else
    fail "local proxy still resolves e2ee-proxy too early at startup"
fi

if grep -q '@chatCustomAssets path /static/custom.css /static/loader.js /static/site.webmanifest' "$PROJECT_DIR/conf/Caddyfile.template" && \
   grep -q 'location = /static/custom.css {' "$PROJECT_DIR/conf/local-proxy.nginx.template" && \
   grep -q 'location = /static/loader.js {' "$PROJECT_DIR/conf/local-proxy.nginx.template" && \
   grep -q 'location = /static/site.webmanifest {' "$PROJECT_DIR/conf/local-proxy.nginx.template"; then
    pass "chat custom assets are served no-store through the edge"
else
    fail "chat custom assets are missing edge no-store protection"
fi

if python3 - "$PROJECT_DIR/branding/openwebui/site.webmanifest" <<'PY' >/dev/null 2>&1
import json
import sys
from pathlib import Path

manifest = json.loads(Path(sys.argv[1]).read_text())
assert manifest["name"] == "Chutes Chat"
assert manifest["short_name"] == "Chutes Chat"
assert manifest["start_url"] == "/chat/"
assert manifest["scope"] == "/chat/"
assert manifest["icons"][0]["src"] == "/chat/static/chutes-chat-icon-192.png"
assert manifest["icons"][1]["src"] == "/chat/static/chutes-chat-icon-512.png"
PY
then
    pass "OpenWebUI manifest is branded for Chutes Chat"
else
    fail "OpenWebUI manifest branding is incomplete"
fi

for placeholder in __INSTALL_MODE__ __CHUTES_TRAFFIC_MODE__ __DROPZONE_HOST__; do
    if grep -q "$placeholder" "$PROJECT_DIR/landing/index.template.html"; then
        pass "landing template has $placeholder"
    else
        fail "landing template missing $placeholder"
    fi
done

openwebui_version_pin="$(sed -n 's/^ARG OPENWEBUI_VERSION=//p' "$PROJECT_DIR/Dockerfile.local-repo" | head -n 1)"
openwebui_image_pin="$(sed -n 's/^ARG OPENWEBUI_IMAGE=//p' "$PROJECT_DIR/Dockerfile.local-repo" | head -n 1)"
case "$openwebui_image_pin" in
    *":${openwebui_version_pin}@sha256:"*)
        pass "Dockerfile pins OpenWebUI by version and digest"
        ;;
    *)
        fail "Dockerfile OpenWebUI pin is missing a matching versioned digest"
        ;;
esac

if grep -q '^OPENWEBUI_IMAGE=' "$PROJECT_DIR/.env.example"; then
    pass ".env.example exposes the pinned OpenWebUI image"
else
    fail ".env.example is missing OPENWEBUI_IMAGE"
fi

if grep -q '^DROPZONE_ENABLE_PUBLIC_LANDING=' "$PROJECT_DIR/.env.example"; then
    pass ".env.example exposes DROPZONE_ENABLE_PUBLIC_LANDING"
else
    fail ".env.example is missing DROPZONE_ENABLE_PUBLIC_LANDING"
fi

if grep -q 'DROPZONE_ENABLE_PUBLIC_LANDING: "false"' "$PROJECT_DIR/examples/kubernetes/standalone-domain-direct.yaml" && \
   grep -q 'DROPZONE_HOST: "chat.chutes.ai"' "$PROJECT_DIR/examples/kubernetes/standalone-domain-direct.yaml"; then
    pass "kubernetes standalone example defaults to chat.chutes.ai with the landing page disabled"
else
    fail "kubernetes standalone example is missing the chat.chutes.ai private-entry defaults"
fi

if grep -q '@sha256:' "$PROJECT_DIR/docker-compose.domain.yml"; then
    pass "domain compose pins the Caddy runtime image by digest"
else
    fail "domain compose is missing a digest-pinned Caddy image"
fi

if grep -q '@sha256:' "$PROJECT_DIR/Dockerfile.local-proxy" && \
   grep -q '@sha256:' "$PROJECT_DIR/Dockerfile.e2ee-proxy"; then
    pass "proxy Dockerfiles pin e2ee-proxy by digest"
else
    fail "proxy Dockerfiles are missing digest-pinned e2ee-proxy images"
fi

ci_nodes_ref="$(sed -n 's/^[[:space:]]*N8N_NODES_CHUTES_REF:[[:space:]]*//p' "$PROJECT_DIR/.github/workflows/ci.yml" | head -n 1)"
release_nodes_ref="$(sed -n 's/^[[:space:]]*N8N_NODES_CHUTES_REF:[[:space:]]*//p' "$PROJECT_DIR/.github/workflows/release.yml" | head -n 1)"
deploy_nodes_ref="$(awk -F'\"' '/^PROJECT_NODES_REF=/{print $2; exit}' "$PROJECT_DIR/deploy.sh")"

if [ -n "$ci_nodes_ref" ] && [ "$ci_nodes_ref" = "$release_nodes_ref" ] && [ "$ci_nodes_ref" = "$deploy_nodes_ref" ]; then
    pass "n8n-nodes-chutes pin matches across ci, release, and deploy"
else
    fail "n8n-nodes-chutes pin drifted across ci, release, or deploy"
fi

if [ "$SYNTAX_ONLY" = true ]; then
    echo
    echo "=== Results: $PASS passed, $FAIL failed, $SKIP skipped ==="
    [ "$FAIL" -eq 0 ]
    exit $?
fi

echo
echo "=== Runtime checks ==="

if [ ! -f "$PROJECT_DIR/.env" ]; then
    fail ".env missing - run deploy.sh first"
    echo
    echo "=== Results: $PASS passed, $FAIL failed, $SKIP skipped ==="
    exit 1
fi

set -a
# shellcheck source=/dev/null
source "$PROJECT_DIR/.env"
set +a

DROPZONE_HOST="${DROPZONE_HOST:-${N8N_HOST:-e2ee-local-proxy.chutes.dev}}"
DROPZONE_ENABLE_PUBLIC_LANDING="${DROPZONE_ENABLE_PUBLIC_LANDING:-true}"
N8N_EDGE_URL="https://${DROPZONE_HOST}/n8n"
CHAT_EDGE_URL="https://${DROPZONE_HOST}/chat"
LANDING_EDGE_URL="https://${DROPZONE_HOST}/"

EDGE_SERVICE="${EDGE_SERVICE:-}"
if [ -z "$EDGE_SERVICE" ]; then
    case "${INSTALL_MODE:-domain}" in
        local) EDGE_SERVICE="local-proxy" ;;
        *) EDGE_SERVICE="caddy" ;;
    esac
fi

WAIT_SERVICES="postgres n8n openwebui $EDGE_SERVICE"
if [ "${CHUTES_TRAFFIC_MODE:-direct}" = "e2ee-proxy" ]; then
    WAIT_SERVICES="$WAIT_SERVICES e2ee-proxy"
fi

for service in $WAIT_SERVICES; do
    status="$(wait_for_service "$service" 30 || true)"
    if [ "$status" = "healthy" ] || [ "$status" = "running" ]; then
        pass "$service container $status"
    else
        fail "$service container status: $status"
    fi
done

if [ "$EDGE_SERVICE" = "caddy" ]; then
    if compose exec -T caddy caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1; then
        pass "caddy validate"
    else
        fail "caddy validate"
    fi
else
    if compose exec -T local-proxy /usr/local/openresty/bin/openresty -t >/dev/null 2>&1; then
        pass "openresty validate"
    else
        fail "openresty validate"
    fi
fi

healthz="$(compose exec -T n8n wget -q -O- http://127.0.0.1:5678/rest/settings 2>/dev/null || echo '')"
if echo "$healthz" | grep -q '"settingsMode"'; then
    pass "n8n /rest/settings responds"
else
    fail "n8n /rest/settings unreachable"
fi

if compose exec -T openwebui python -c \
    "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/', timeout=5).read()" \
    >/dev/null 2>&1; then
    pass "OpenWebUI responds on port 8080"
else
    fail "OpenWebUI is unreachable on port 8080"
fi

landing_headers="$(curl_edge -skI "$LANDING_EDGE_URL" 2>/dev/null | tr -d '\r' || true)"
if echo "$landing_headers" | grep -qi '^X-Content-Type-Options: nosniff' && \
   echo "$landing_headers" | grep -qi '^X-Frame-Options: SAMEORIGIN' && \
   echo "$landing_headers" | grep -qi '^Referrer-Policy: strict-origin-when-cross-origin' && \
   echo "$landing_headers" | grep -qi '^Strict-Transport-Security:' && \
   echo "$landing_headers" | grep -qi '^Permissions-Policy:'; then
    pass "public app edge sends baseline security headers"
else
    fail "public app edge is missing baseline security headers"
fi

if echo "$landing_headers" | grep -qi '^Access-Control-Allow-Origin: \*'; then
    fail "public app edge is exposing wildcard CORS outside the /v1 API surface"
else
    pass "public app edge does not expose wildcard CORS headers"
fi

if [ "$DROPZONE_ENABLE_PUBLIC_LANDING" = "true" ]; then
    landing_html="$(curl_edge -sk "$LANDING_EDGE_URL" 2>/dev/null || true)"
    if echo "$landing_html" | grep -q '/chat/' && echo "$landing_html" | grep -q '/n8n/'; then
        pass "landing page is reachable and links to /chat/ and /n8n/"
    else
        fail "landing page is missing launch links"
    fi

    landing_css_headers="$(curl_edge -skI "https://${DROPZONE_HOST}/_dropzone/styles.css" 2>/dev/null || true)"
    if echo "$landing_css_headers" | grep -qi '^Content-Type: text/css'; then
        pass "landing stylesheet is served as text/css"
    else
        fail "landing stylesheet content type is not text/css"
    fi

    if echo "$landing_headers" | grep -qi '^Cache-Control: no-store'; then
        pass "landing HTML disables stale browser caching"
    else
        fail "landing HTML is missing Cache-Control: no-store"
    fi
else
    if echo "$landing_headers" | grep -qi '^HTTP/.* 302' && \
       { echo "$landing_headers" | grep -qi '^location: /chat/$' || \
         echo "$landing_headers" | grep -qi "^location: https\\?://${DROPZONE_HOST}/chat/$"; }; then
        pass "root entry redirects straight to /chat/ when public landing is disabled"
    else
        fail "root entry did not redirect to /chat/ with DROPZONE_ENABLE_PUBLIC_LANDING=false"
    fi
fi

auth_headers="$(curl_edge -skI "https://${DROPZONE_HOST}/auth?redirect=%2Fchat%2F" 2>/dev/null || true)"
if echo "$auth_headers" | grep -qi '^HTTP/.* 200'; then
    pass "root OpenWebUI auth alias is served directly"
else
    fail "root OpenWebUI auth alias did not return a login page"
fi

openwebui_account_status="$(curl_edge -sk -o /tmp/chutes-dropzone.openwebui-account.out -w '%{http_code}' \
    "https://${DROPZONE_HOST}/api/v1/dropzone/account-summary" 2>/dev/null || echo 000)"
case "$openwebui_account_status" in
    401|403)
        pass "OpenWebUI account-summary endpoint rejects anonymous requests"
        ;;
    *)
        fail "OpenWebUI account-summary endpoint returned unexpected anonymous status $openwebui_account_status"
        ;;
esac

chat_status="$(curl_edge -sk -o /tmp/chutes-dropzone.chat.out -w '%{http_code}' "$CHAT_EDGE_URL/" 2>/dev/null || echo 000)"
case "$chat_status" in
    302)
        if curl_edge -skI "$CHAT_EDGE_URL/" 2>/dev/null | grep -qi "^location: .*${DROPZONE_HOST}/home\\|^location: /home"; then
            pass "OpenWebUI /chat/ entrypoint redirects into the native app home route"
        else
            fail "OpenWebUI /chat/ entrypoint did not redirect to /home"
        fi
        ;;
    *)
        fail "OpenWebUI /chat/ route returned status $chat_status"
        ;;
esac

chat_alias_bad_headers="$(curl_edge -skI "https://${DROPZONE_HOST}/chat//evil.example" 2>/dev/null | tr -d '\r' || true)"
if echo "$chat_alias_bad_headers" | grep -qi '^location: /home$' || \
   echo "$chat_alias_bad_headers" | grep -qi "^location: https\\?://${DROPZONE_HOST}/home$"; then
    pass "OpenWebUI chat alias sends malformed double-slash paths to /home"
else
    fail "OpenWebUI chat alias did not safely normalize malformed double-slash paths"
fi

chat_native_html="$(curl_edge -sk "https://${DROPZONE_HOST}/home" 2>/dev/null || true)"
if echo "$chat_native_html" | grep -q 'href="/_app/' &&
   echo "$chat_native_html" | grep -q 'src="/static/' &&
   ! echo "$chat_native_html" | grep -q 'base: "/chat"'; then
    pass "OpenWebUI frontend HTML uses native root routes"
else
    fail "OpenWebUI frontend HTML is not using the native root route layout"
fi

oauth_login_headers="$(curl_edge -skD- "https://${DROPZONE_HOST}/oauth/oidc/login" -o /dev/null 2>/dev/null || true)"
if echo "$oauth_login_headers" | grep -qi '^HTTP/.* 30[27]' &&
   echo "$oauth_login_headers" | grep -qi "redirect_uri=https%3A%2F%2F${DROPZONE_HOST}%2Foauth%2Foidc%2Fcallback"; then
    pass "OpenWebUI OIDC login uses the root OAuth callback alias"
else
    fail "OpenWebUI OIDC login is not requesting the root OAuth callback alias"
fi

signin_html="$(curl_edge -sk "${N8N_EDGE_URL}/signin" 2>/dev/null || true)"
if [ -n "$signin_html" ]; then
    pass "n8n sign-in page reachable at /n8n/"
else
    fail "n8n sign-in page unreachable at /n8n/"
fi

n8n_account_status="$(curl_edge -sk -o /tmp/chutes-dropzone.n8n-account.out -w '%{http_code}' \
    "https://${DROPZONE_HOST}/n8n/rest/sso/chutes/account-summary" 2>/dev/null || echo 000)"
case "$n8n_account_status" in
    401|403)
        pass "n8n account-summary endpoint rejects anonymous requests"
        ;;
    *)
        fail "n8n account-summary endpoint returned unexpected anonymous status $n8n_account_status"
        ;;
esac

settings_json="$(curl_edge -sk "${N8N_EDGE_URL}/rest/settings" 2>/dev/null || true)"
sso_enabled="$(printf '%s' "$settings_json" | json_query '.data.sso.chutes.loginEnabled' 2>/dev/null || true)"
sso_label="$(printf '%s' "$settings_json" | json_query '.data.sso.chutes.loginLabel' 2>/dev/null || true)"
if [ "$sso_enabled" = "true" ] && [ "$sso_label" = "${CHUTES_SSO_LOGIN_LABEL:-Login with Chutes}" ]; then
    pass "frontend settings expose Chutes SSO"
else
    fail "frontend settings are missing Chutes SSO"
fi

if compose exec -T n8n node - <<'NODE' >/dev/null 2>&1
const { CredentialsHelper } = require('/usr/local/lib/node_modules/n8n/dist/credentials-helper.js');

(async () => {
	const helper = Object.create(CredentialsHelper.prototype);
	let updateCalled = false;

	helper.credentialTypes = {
		getByName() {
			return {
				name: 'chutesApi',
				properties: [
					{ name: 'sessionToken', type: 'hidden', typeOptions: { expirable: true } },
					{ name: 'tokenExpiresAt', type: 'hidden' },
				],
				async preAuthentication() {
					return {
						sessionToken: 'fresh-session-token',
						refreshToken: 'fresh-refresh-token',
						tokenExpiresAt: new Date(Date.now() + 60 * 60 * 1000).toISOString(),
					};
				},
			};
		},
	};

	helper.updateCredentials = async () => {
		updateCalled = true;
	};

	const result = await helper.preAuthentication(
		{ helpers: {} },
		{
			sessionToken: 'stale-session-token',
			refreshToken: 'stale-refresh-token',
			tokenExpiresAt: '1970-01-01T00:00:00.000Z',
		},
		'chutesApi',
		{
			type: 'n8n-nodes-chutes.chutes',
			parameters: {},
			credentials: {
				chutesApi: {
					id: 'cred-1',
					name: 'Chutes SSO',
				},
			},
		},
		false,
	);

	if (!updateCalled || result?.refreshToken !== 'fresh-refresh-token') {
		throw new Error('expirable credential helper did not refresh an expiring token');
	}
})().catch((error) => {
	console.error(error);
	process.exit(1);
});
NODE
then
    pass "expirable credentials refresh before token expiry"
else
    fail "expirable credentials did not refresh before token expiry"
fi

sso_headers="$(curl_edge -skI "${N8N_EDGE_URL}/rest/sso/chutes/login" 2>/dev/null || true)"
encoded_n8n_callback="https%3A%2F%2F${DROPZONE_HOST}%2Frest%2Fsso%2Fchutes%2Fcallback"
if echo "$sso_headers" | grep -qi '^location: .*idp/authorize' && \
   echo "$sso_headers" | grep -q "redirect_uri=${encoded_n8n_callback}" && \
   ! echo "$sso_headers" | grep -q 'scope=.*email'; then
    pass "native Chutes SSO endpoint redirects to the IDP with the root callback alias and current Chutes scopes"
else
    fail "native Chutes SSO endpoint did not use the root callback alias and current Chutes scopes"
fi

# shellcheck disable=SC2016
if compose exec -T openwebui sh -lc '
    case "${WEBUI_URL:-}" in https://*/chat) ;; *) exit 1 ;; esac
    case "${OPENID_REDIRECT_URI:-}" in https://*/oauth/oidc/callback|https://*/chat/oauth/oidc/callback) ;; *) exit 1 ;; esac
    test "${OAUTH_SCOPES:-}" = "openid profile chutes:read chutes:invoke" &&
    test "${OAUTH_USERNAME_CLAIM:-}" = "username" &&
    test "${ENABLE_PERSISTENT_CONFIG:-}" = "false" &&
    test "${ENABLE_OAUTH_PERSISTENT_CONFIG:-}" = "false" &&
    test "${ENABLE_OAUTH_SIGNUP:-}" = "true" &&
    test "${DEFAULT_USER_ROLE:-}" = "user" &&
    test "${BYPASS_MODEL_ACCESS_CONTROL:-}" = "true" &&
    test "${ENABLE_OAUTH_EMAIL_FALLBACK:-}" = "true" &&
    test "${ENABLE_LOGIN_FORM:-}" = "false" &&
    test "${ENABLE_PASSWORD_AUTH:-}" = "false" &&
    test "${MODELS_CACHE_TTL:-}" = "300"
' >/dev/null 2>&1; then
    pass "OpenWebUI env is pinned to /chat and SSO-only mode"
else
    fail "OpenWebUI env is missing the expected /chat SSO-only settings"
fi

# shellcheck disable=SC2016
if compose exec -T openwebui-order-sync sh -lc '
    test "${OPENWEBUI_SYNC_BASE_URL:-}" = "http://openwebui:8080" &&
    test "${OPENWEBUI_MODEL_ORDER_SYNC_INTERVAL:-}" = "300"
' >/dev/null 2>&1; then
    pass "OpenWebUI background model-order sync worker is configured for 5-minute refreshes"
else
    fail "OpenWebUI background model-order sync worker is missing the expected settings"
fi

openwebui_oauth_headers="$(curl_edge -sk -o /dev/null -D - "https://${DROPZONE_HOST}/oauth/oidc/login" 2>/dev/null || true)"
if echo "$openwebui_oauth_headers" | grep -qi '^location: .*idp/authorize' && \
   ! echo "$openwebui_oauth_headers" | grep -q 'scope=.*email'; then
    pass "OpenWebUI OIDC login uses the current Chutes-supported scopes"
else
    fail "OpenWebUI OIDC login is still requesting unsupported Chutes scopes"
fi

if compose exec -T n8n sh -lc \
    "grep -R 'restApiContext.baseUrl}/sso/chutes/login' /usr/local/lib/node_modules/n8n/node_modules/n8n-editor-ui/dist/assets >/dev/null"; then
    pass "editor bundle uses REST base URL for Chutes login"
else
    fail "editor bundle is missing the REST base URL Chutes login fix"
fi

if compose exec -T n8n sh -lc \
    "grep -R 'toggle-password-login' /usr/local/lib/node_modules/n8n/node_modules/n8n-editor-ui/dist/assets >/dev/null" && \
   compose exec -T n8n sh -lc \
    "grep -R 'Login using other credentials' /usr/local/lib/node_modules/n8n/node_modules/n8n-editor-ui/dist/assets >/dev/null"; then
    pass "editor bundle includes the local-login reveal flow"
else
    fail "editor bundle is missing the local-login reveal flow"
fi

http_status="$(curl_edge -s -o /dev/null -w '%{http_code}' "http://${DROPZONE_HOST}/" 2>/dev/null || echo 000)"
if [ "$http_status" = "308" ] || [ "$http_status" = "301" ]; then
    pass "HTTP redirects to HTTPS"
else
    fail "HTTP did not redirect to HTTPS (status $http_status)"
fi

owner_login="$(curl_edge -sk -c /tmp/chutes-n8n-local.cookies \
    -H 'Content-Type: application/json' \
    -H 'browser-id: smoke-test-browser' \
    -d "$(printf '{"emailOrLdapLoginId":"%s","password":"%s"}' "$N8N_ADMIN_EMAIL" "$N8N_ADMIN_PASSWORD")" \
    "${N8N_EDGE_URL}/rest/login" 2>/dev/null || true)"
if echo "$owner_login" | grep -q '"id"'; then
    pass "break-glass owner login works"
else
    fail "break-glass owner login failed"
fi

if compose exec -T n8n n8n export:nodes --output=/tmp/nodes.json >/dev/null 2>&1 && \
    compose exec -T n8n node - <<'NODE' >/dev/null 2>&1
const fs = require('fs');

const nodes = JSON.parse(fs.readFileSync('/tmp/nodes.json', 'utf8'));
const required = ['CUSTOM.chutes', 'CUSTOM.chutesChatModel', 'CUSTOM.chutesAIAgent'];
const missing = required.filter((name) => !nodes.some((node) => node.name === name));

if (missing.length > 0) {
	console.error(`Missing custom nodes: ${missing.join(', ')}`);
	process.exit(1);
}
NODE
then
    pass "custom nodes are registered in n8n"
else
    fail "custom nodes are not registered in n8n"
fi

if [ "${CHUTES_TRAFFIC_MODE:-direct}" = "e2ee-proxy" ]; then
    # shellcheck disable=SC2016
    if compose exec -T n8n sh -lc '
        test "${CHUTES_SSO_PROXY_BYPASS:-false}" = "false" &&
        test "${CHUTES_PROXY_BASE_URL:-}" = "http://e2ee-proxy:80"
    ' >/dev/null 2>&1; then
        pass "n8n SSO text traffic is pinned to the proxy path in e2ee-proxy mode"
    else
        fail "n8n still allows SSO text traffic to bypass the proxy path"
    fi

    if compose exec -T n8n sh -lc "NODE_PATH=/usr/local/lib/node_modules/n8n/node_modules node -e 'const Module=require(\"module\"); Module._initPaths(); const transport=require(\"/opt/custom-nodes/n8n-nodes-chutes/dist/nodes/Chutes/transport/apiRequest.js\"); const ok=!transport.isSsoProxyBypassEnabled() && transport.shouldUseTextProxyForCredential({authType:\"sso\",sessionToken:\"session-token\"}); process.exit(ok ? 0 : 1);'" >/dev/null 2>&1; then
        pass "n8n runtime logic routes SSO-backed text requests through the proxy"
    else
        fail "n8n runtime logic still bypasses the proxy for SSO-backed text requests"
    fi

    # shellcheck disable=SC2016
    if compose exec -T openwebui sh -lc '
        test "${OPENAI_API_BASE_URLS:-}" = "http://e2ee-proxy:80/v1"
    ' >/dev/null 2>&1; then
        pass "OpenWebUI is pinned to the proxy-backed /v1 model endpoint in e2ee-proxy mode"
    else
        fail "OpenWebUI is still pointing directly at native Chutes model endpoints"
    fi

    proxy_models_headers="/tmp/chutes-n8n-local.proxy-models.headers"
    proxy_models_status="$(curl_edge -sk -D "$proxy_models_headers" -o /tmp/chutes-n8n-local.proxy-models.out -w '%{http_code}' \
        "https://${DROPZONE_HOST}/v1/models" 2>/dev/null || echo 000)"
    if [ "$proxy_models_status" = "200" ]; then
        pass "e2ee-proxy exposes /v1/models on the local edge"
    else
        echo "    e2ee-proxy /v1/models body: $(head -c 500 /tmp/chutes-n8n-local.proxy-models.out 2>/dev/null)" >&2
        compose logs e2ee-proxy --tail 20 2>/dev/null | sed 's/^/    /' >&2 || true
        fail "e2ee-proxy /v1/models route returned status $proxy_models_status"
    fi

    if [ "$proxy_models_status" = "200" ]; then
        if grep -qi '^Access-Control-Allow-Origin: \*' "$proxy_models_headers"; then
            pass "e2ee-proxy keeps wildcard CORS scoped to the shared /v1 API surface"
        else
            fail "e2ee-proxy /v1/models is missing the expected API CORS header"
        fi

        if grep -qi '^X-Dropzone-Proxy: e2ee-proxy' "$proxy_models_headers"; then
            pass "proxy model catalog responses identify the e2ee-proxy path"
        else
            fail "proxy model catalog responses are missing the e2ee-proxy marker header"
        fi

        if python3 - /tmp/chutes-n8n-local.proxy-models.out <<'PY' >/dev/null 2>&1
import json
import sys

payload = json.load(open(sys.argv[1], "r", encoding="utf-8"))
models = payload.get("data", []) if isinstance(payload, dict) else []
if not isinstance(models, list) or not models:
    raise SystemExit(1)
if any(not isinstance(model, dict) or not model.get("id") for model in models):
    raise SystemExit(1)
PY
        then
            pass "proxy model catalog returns an anonymous public model list"
        else
            fail "proxy model catalog did not return a valid anonymous public model list"
        fi

        if [ "${ALLOW_NON_CONFIDENTIAL:-false}" != "true" ]; then
            if grep -qi '^X-Dropzone-Model-Catalog: tee-only' "$proxy_models_headers" && \
               python3 - /tmp/chutes-n8n-local.proxy-models.out <<'PY' >/dev/null 2>&1
import json
import sys

payload = json.load(open(sys.argv[1], "r", encoding="utf-8"))
models = payload.get("data", []) if isinstance(payload, dict) else []
if not models:
    raise SystemExit(1)
if any(model.get("confidential_compute") is not True for model in models):
    raise SystemExit(1)
PY
            then
                pass "strict e2ee-proxy mode filters the shared /v1/models catalog down to TEE models"
            else
                fail "strict e2ee-proxy mode did not filter the shared /v1/models catalog to TEE models"
            fi

            if compose exec -T openwebui python - <<'PY' >/dev/null 2>&1
import json
import os
import urllib.request
from datetime import timedelta

from open_webui.internal.db import get_db
from open_webui.models.users import Users
from open_webui.utils.auth import create_token

admin_email = (
    os.environ.get("ADMIN_EMAIL")
    or os.environ.get("WEBUI_ADMIN_EMAIL")
    or os.environ.get("OPENWEBUI_ADMIN_EMAIL")
    or "admin@chutes.local"
)

with get_db() as db:
    admin_user = Users.get_user_by_email(admin_email, db)

if not admin_user:
    raise SystemExit(1)

token = create_token({"id": admin_user.id}, expires_delta=timedelta(minutes=5))
request = urllib.request.Request(
    "http://127.0.0.1:8080/api/models?refresh=true",
    headers={"Authorization": f"Bearer {token}", "Accept": "application/json"},
)
with urllib.request.urlopen(request, timeout=20) as response:
    payload = json.loads(response.read().decode("utf-8"))

models = payload.get("data", []) if isinstance(payload, dict) else []
if not models:
    raise SystemExit(1)
if any(model.get("confidential_compute") is not True for model in models):
    raise SystemExit(1)
PY
            then
                pass "OpenWebUI only exposes TEE text models when strict e2ee-proxy mode is enabled"
            else
                fail "OpenWebUI still exposes non-TEE models in strict e2ee-proxy mode"
            fi
        fi
    fi

    proxy_chat_headers="/tmp/chutes-n8n-local.proxy-chat.headers"
    proxy_chat_status="$(curl_edge -sk -D "$proxy_chat_headers" -o /tmp/chutes-n8n-local.proxy-chat.out -w '%{http_code}' \
        -H 'Content-Type: application/json' \
        -d '{"model":"Qwen/Qwen3-32B","messages":[{"role":"user","content":"hello"}],"stream":false}' \
        "https://${DROPZONE_HOST}/v1/chat/completions" 2>/dev/null || echo 000)"
    case "$proxy_chat_status" in
        200|400|401|403)
            pass "e2ee-proxy handles /v1/chat/completions on the local edge"
            ;;
        *)
            fail "e2ee-proxy /v1/chat/completions route returned status $proxy_chat_status"
            ;;
    esac

    if grep -qi '^X-Dropzone-Proxy: e2ee-proxy' "$proxy_chat_headers"; then
        pass "proxy chat-completion responses identify the e2ee-proxy path"
    else
        fail "proxy chat-completion responses are missing the e2ee-proxy marker header"
    fi
else
    direct_v1_status="$(curl_edge -sk -o /dev/null -w '%{http_code}' \
        "https://${DROPZONE_HOST}/v1/models" 2>/dev/null || echo 000)"
    case "$direct_v1_status" in
        401|403|404)
            pass "direct mode does not expose the shared /v1 edge"
            ;;
        *)
            fail "direct mode unexpectedly exposed /v1/models with status $direct_v1_status"
            ;;
    esac
fi

credentials_response="$(curl_edge -sk -b /tmp/chutes-n8n-local.cookies \
    -H 'browser-id: smoke-test-browser' \
    "${N8N_EDGE_URL}/rest/credentials" 2>/dev/null || true)"

if command -v jq >/dev/null 2>&1; then
    sso_credential_id="$(printf '%s' "$credentials_response" | jq -r '.data[] | select(.type == "chutesApi" and .name == "Chutes SSO") | .id' | head -n 1)"
    if [ -n "$sso_credential_id" ] && [ "$sso_credential_id" != "null" ]; then
        dynamic_payload="$(jq -nc --arg id "$sso_credential_id" '{
            credentials: {
                chutesApi: {
                    id: $id,
                    name: "Chutes SSO"
                }
            },
            currentNodeParameters: {
                resource: "imageGeneration",
                chuteUrl: "https://image.chutes.ai",
                operation: "generate",
                prompt: "",
                size: "1024x1024",
                n: 1,
                additionalOptions: {}
            },
            nodeTypeAndVersion: {
                name: "CUSTOM.chutes",
                version: 1
            },
            methodName: "getImageChutes",
            path: "chuteUrl"
        }')"
        dynamic_options_response="$(curl_edge -sk -b /tmp/chutes-n8n-local.cookies \
            -H 'Content-Type: application/json' \
            -H 'browser-id: smoke-test-browser' \
            -d "$dynamic_payload" \
            "${N8N_EDGE_URL}/rest/dynamic-node-parameters/options" 2>/dev/null || true)"
        dynamic_options_count="$(printf '%s' "$dynamic_options_response" | jq -r '.data | length')"
        if [[ "$dynamic_options_count" =~ ^[0-9]+$ ]] && [ "$dynamic_options_count" -gt 0 ]; then
            pass "Chutes SSO credential loads chute options"
        else
            fail "Chutes SSO credential did not load chute options"
        fi
    else
        skip "no Chutes SSO credential present - skipping chute option load check"
    fi
else
    skip "jq not installed - cannot validate Chutes SSO option loading"
fi

rm -f /tmp/chutes-n8n-local.cookies

echo
echo "=== Results: $PASS passed, $FAIL failed, $SKIP skipped ==="
[ "$FAIL" -eq 0 ]
