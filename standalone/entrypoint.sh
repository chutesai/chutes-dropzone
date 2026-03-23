#!/bin/sh
#
# chutes-n8n-local standalone entrypoint
#
# Supports all deploy.sh modes as runtime switches:
#   INSTALL_MODE    local | domain
#   CHUTES_TRAFFIC_MODE   direct | e2ee-proxy
#   --reconfigure   re-enter interactive prompts
#   --wipe          destroy data and re-initialize
#
# Compose-mode fallback: if DB_TYPE=postgresdb is set, skip standalone
# logic and exec the original n8n entrypoint.
#
set -eu

DATA_DIR="/data"
ENV_FILE="$DATA_DIR/.env"
SENTINEL="$DATA_DIR/.configured"
N8N_STATE_DIR="$DATA_DIR/.n8n"
OPENWEBUI_STATE_DIR="$DATA_DIR/openwebui"
CADDY_DATA="$DATA_DIR/caddy"
LOCAL_HOSTNAME="e2ee-local-proxy.chutes.dev"
RECONFIGURE=false
WIPE=false
DEFAULT_CHUTES_SSO_SCOPES="openid profile chutes:read chutes:invoke"
LEGACY_CHUTES_SSO_SCOPES="openid email profile chutes:read chutes:invoke"

# ---------------------------------------------------------------------------
# Compose-mode detection: if DB_TYPE=postgresdb, this container is running
# inside the compose stack managed by deploy.sh.  Skip standalone logic.
# ---------------------------------------------------------------------------
if [ "${DB_TYPE:-}" = "postgresdb" ]; then
    exec tini -- /docker-entrypoint.sh "$@"
fi

# ---------------------------------------------------------------------------
# Parse flags
# ---------------------------------------------------------------------------
for arg in "$@"; do
    case "$arg" in
        --reconfigure) RECONFIGURE=true ;;
        --wipe) WIPE=true ;;
    esac
done

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'

info()  { printf "${CYAN}[*]${NC} %s\n" "$*"; }
ok()    { printf "${GREEN}[+]${NC} %s\n" "$*"; }
warn()  { printf "${YELLOW}[!]${NC} %s\n" "$*"; }
err()   { printf "${RED}[x]${NC} %s\n" "$*" >&2; }

# ---------------------------------------------------------------------------
# Interactive helpers (mirrors deploy.sh)
# ---------------------------------------------------------------------------
INTERACTIVE=false
[ -t 0 ] && [ -t 1 ] && INTERACTIVE=true

read_value() {
    _var_name="$1"
    _prompt="$2"
    _secret="${3:-false}"

    if [ "$INTERACTIVE" != true ]; then
        err "$_var_name must be set in non-interactive mode"
        exit 1
    fi

    printf '%s' "$_prompt"
    if [ "$_secret" = true ]; then
        stty -echo 2>/dev/null || true
        IFS= read -r _val
        stty echo 2>/dev/null || true
        printf '\n'
    else
        IFS= read -r _val
    fi

    eval "$_var_name=\$_val"
}

prompt_required() {
    _var_name="$1"
    _prompt="$2"
    _secret="${3:-false}"
    _prompt_existing="${4:-false}"

    eval "_current=\${$_var_name:-}"
    if [ -n "$_current" ] && { [ "$_prompt_existing" != true ] || [ "$INTERACTIVE" != true ]; }; then
        return 0
    fi

    if [ -n "$_current" ] && [ "$_prompt_existing" = true ]; then
        if [ "$_secret" = true ]; then
            read_value _next_value "  $_prompt [press Enter to keep current value]: " true
        else
            read_value _next_value "  $_prompt [$_current]: " false
        fi
        if [ -n "${_next_value:-}" ]; then
            eval "$_var_name=\$_next_value"
        fi
    else
        read_value "$_var_name" "  $_prompt: " "$_secret"
    fi

    eval "_current=\${$_var_name:-}"
    if [ -z "$_current" ]; then
        err "$_var_name must not be empty"
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Secret generation (mirrors deploy.sh)
# ---------------------------------------------------------------------------
generate_hex() {
    openssl rand -hex "$1"
}

generate_owner_password() {
    _lower="$(openssl rand -hex 6 | tr 'A-F' 'a-f')"
    _upper="$(openssl rand -hex 4 | tr 'a-f' 'A-F')"
    _digits="$(openssl rand -hex 4 | tr -dc '0-9' | cut -c1-4)"

    while [ "${#_digits}" -lt 4 ]; do
        _digits="${_digits}$(openssl rand -hex 1 | tr -dc '0-9')"
        _digits="$(echo "$_digits" | cut -c1-4)"
    done

    printf 'Ch%s%s%s' "$_upper" "$_lower" "$_digits"
}

# ---------------------------------------------------------------------------
# Env file helpers
# ---------------------------------------------------------------------------
env_escape() {
    _v="$1"
    # shellcheck disable=SC2016
    _v="$(printf '%s' "$_v" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\$/\\$/g' -e 's/`/\\`/g')"
    printf '"%s"' "$_v"
}

env_line() {
    printf '%s=%s\n' "$1" "$(env_escape "$2")"
}

render_template_file() {
    TEMPLATE_PATH="$1" OUTPUT_PATH="$2" python3 - <<'PY'
import os
from pathlib import Path

template = Path(os.environ["TEMPLATE_PATH"]).read_text(encoding="utf-8")
replacements = {
    "__SERVER_NAME__": os.environ.get("TEMPLATE_SERVER_NAME", ""),
    "__TLS_DIRECTIVE__": os.environ.get("TEMPLATE_TLS_DIRECTIVE", ""),
    "__RESOLVERS__": os.environ.get("TEMPLATE_RESOLVERS", ""),
    "__CHUTES_V1_BLOCK__": os.environ.get("TEMPLATE_CHUTES_V1_BLOCK", ""),
}

for placeholder, value in replacements.items():
    template = template.replace(placeholder, value)

Path(os.environ["OUTPUT_PATH"]).write_text(template, encoding="utf-8")
PY
}

caddy_chutes_v1_block() {
    if [ "$CHUTES_TRAFFIC_MODE" != "e2ee-proxy" ]; then
        return
    fi

    cat <<'EOF'
    @chutes_v1 path /v1/*
    reverse_proxy @chutes_v1 https://127.0.0.1:8443 {
        header_up Host 127.0.0.1
        transport http {
            tls_insecure_skip_verify
        }
    }

EOF
}

nginx_chutes_v1_block() {
    if [ "$CHUTES_TRAFFIC_MODE" != "e2ee-proxy" ]; then
        return
    fi

    cat <<'EOF'
        location = /v1/models {
            if ($request_method = 'OPTIONS') {
                more_set_headers 'Access-Control-Allow-Origin: *';
                more_set_headers 'Access-Control-Allow-Methods: GET, HEAD, OPTIONS';
                more_set_headers 'Access-Control-Allow-Headers: *';
                more_set_headers 'Access-Control-Max-Age: 86400';
                more_set_headers 'Content-Length: 0';
                return 204;
            }

            content_by_lua_block {
                local handler = require("model_catalog")
                handler.handle()
            }
        }

        location = /v1/messages {
            if ($request_method = 'OPTIONS') {
                more_set_headers 'Access-Control-Allow-Origin: *';
                more_set_headers 'Access-Control-Allow-Methods: GET, POST, OPTIONS';
                more_set_headers 'Access-Control-Allow-Headers: *';
                more_set_headers 'Access-Control-Max-Age: 86400';
                more_set_headers 'Content-Length: 0';
                return 204;
            }

            more_set_headers 'X-Dropzone-Proxy: e2ee-proxy';

            content_by_lua_block {
                local handler = require("claude_handler")
                handler.handle()
            }
        }

        location = /v1/responses {
            if ($request_method = 'OPTIONS') {
                more_set_headers 'Access-Control-Allow-Origin: *';
                more_set_headers 'Access-Control-Allow-Methods: GET, POST, OPTIONS';
                more_set_headers 'Access-Control-Allow-Headers: *';
                more_set_headers 'Access-Control-Max-Age: 86400';
                more_set_headers 'Content-Length: 0';
                return 204;
            }

            more_set_headers 'X-Dropzone-Proxy: e2ee-proxy';

            content_by_lua_block {
                local handler = require("responses_handler")
                handler.handle()
            }
        }

        location /v1/ {
            if ($request_method = 'OPTIONS') {
                more_set_headers 'Access-Control-Allow-Origin: *';
                more_set_headers 'Access-Control-Allow-Methods: GET, POST, OPTIONS';
                more_set_headers 'Access-Control-Allow-Headers: *';
                more_set_headers 'Access-Control-Max-Age: 86400';
                more_set_headers 'Content-Length: 0';
                return 204;
            }

            more_set_headers 'X-Dropzone-Proxy: e2ee-proxy';

            content_by_lua_block {
                local handler = require("e2ee_handler")
                handler.handle()
            }
        }

EOF
}

load_env_file() {
    set -a
    # shellcheck source=/dev/null
    . "$1"
    set +a
}

write_env_file() {
    {
        echo "# chutes-dropzone standalone config — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo
        env_line INSTALL_MODE "$INSTALL_MODE"
        env_line CHUTES_TRAFFIC_MODE "$CHUTES_TRAFFIC_MODE"
        env_line ALLOW_NON_CONFIDENTIAL "$ALLOW_NON_CONFIDENTIAL"
        env_line CHUTES_SSO_PROXY_BYPASS "$CHUTES_SSO_PROXY_BYPASS"
        env_line CHUTES_PROXY_BASE_URL "$CHUTES_PROXY_BASE_URL"
        env_line CHUTES_CREDENTIAL_TEST_BASE_URL "$CHUTES_CREDENTIAL_TEST_BASE_URL"
        echo
        env_line DROPZONE_HOST "$DROPZONE_HOST"
        env_line N8N_HOST "$N8N_HOST"
        env_line ACME_EMAIL "${ACME_EMAIL:-}"
        env_line TZ "${TZ:-UTC}"
        echo
        env_line N8N_ENCRYPTION_KEY "$N8N_ENCRYPTION_KEY"
        env_line N8N_JWT_SECRET "$N8N_JWT_SECRET"
        env_line N8N_ADMIN_EMAIL "$N8N_ADMIN_EMAIL"
        env_line N8N_ADMIN_PASSWORD "$N8N_ADMIN_PASSWORD"
        env_line N8N_EXPIRABLE_CREDENTIAL_REFRESH_WINDOW_SECONDS "${N8N_EXPIRABLE_CREDENTIAL_REFRESH_WINDOW_SECONDS:-300}"
        echo
        env_line WEBUI_SECRET_KEY "$WEBUI_SECRET_KEY"
        env_line OPENWEBUI_NAME "$OPENWEBUI_NAME"
        env_line OPENWEBUI_ADMIN_NAME "$OPENWEBUI_ADMIN_NAME"
        env_line OPENWEBUI_ADMIN_EMAIL "$OPENWEBUI_ADMIN_EMAIL"
        env_line OPENWEBUI_ADMIN_PASSWORD "$OPENWEBUI_ADMIN_PASSWORD"
        env_line OPENWEBUI_API_BASE_URL "$OPENWEBUI_API_BASE_URL"
        env_line OPENWEBUI_API_KEY "${OPENWEBUI_API_KEY:-}"
        env_line OPENWEBUI_MODELS_CACHE_TTL "${OPENWEBUI_MODELS_CACHE_TTL:-300}"
        env_line OPENWEBUI_MODEL_ORDER_SYNC_INTERVAL "${OPENWEBUI_MODEL_ORDER_SYNC_INTERVAL:-300}"
        echo
        env_line CHUTES_OAUTH_CLIENT_ID "$CHUTES_OAUTH_CLIENT_ID"
        env_line CHUTES_OAUTH_CLIENT_SECRET "$CHUTES_OAUTH_CLIENT_SECRET"
        env_line CHUTES_IDP_BASE_URL "${CHUTES_IDP_BASE_URL:-https://api.chutes.ai}"
        env_line CHUTES_SSO_LOGIN_LABEL "${CHUTES_SSO_LOGIN_LABEL:-Login with Chutes}"
        env_line CHUTES_SSO_SCOPES "${CHUTES_SSO_SCOPES:-$DEFAULT_CHUTES_SSO_SCOPES}"
        env_line CHUTES_ADMIN_USERNAMES "${CHUTES_ADMIN_USERNAMES:-}"
        env_line CHUTES_API_KEY "${CHUTES_API_KEY:-}"
    } > "$ENV_FILE"

    chmod 600 "$ENV_FILE"
}

# ---------------------------------------------------------------------------
# Ensure /data exists and is writable
# ---------------------------------------------------------------------------
mkdir -p "$N8N_STATE_DIR" "$OPENWEBUI_STATE_DIR" "$CADDY_DATA"

# ---------------------------------------------------------------------------
# Wipe mode
# ---------------------------------------------------------------------------
if [ "$WIPE" = true ]; then
    warn "Wipe mode: destroying existing data"
    if [ -f "$ENV_FILE" ]; then
        load_env_file "$ENV_FILE"
    fi
    rm -rf "${N8N_STATE_DIR:?}" "${OPENWEBUI_STATE_DIR:?}" "${CADDY_DATA:?}" "$SENTINEL" "$ENV_FILE"
    mkdir -p "$N8N_STATE_DIR" "$OPENWEBUI_STATE_DIR" "$CADDY_DATA"
fi

# ---------------------------------------------------------------------------
# Configuration: load existing or run interactive setup
# ---------------------------------------------------------------------------
if [ -f "$SENTINEL" ] && [ "$RECONFIGURE" != true ]; then
    info "Loading existing configuration"
    load_env_file "$ENV_FILE"
else
    # Defaults
    INSTALL_MODE="${INSTALL_MODE:-}"
    CHUTES_TRAFFIC_MODE="${CHUTES_TRAFFIC_MODE:-direct}"
    ALLOW_NON_CONFIDENTIAL="${ALLOW_NON_CONFIDENTIAL:-false}"
    CHUTES_SSO_PROXY_BYPASS="${CHUTES_SSO_PROXY_BYPASS:-false}"
    CHUTES_OAUTH_CLIENT_ID="${CHUTES_OAUTH_CLIENT_ID:-}"
    CHUTES_OAUTH_CLIENT_SECRET="${CHUTES_OAUTH_CLIENT_SECRET:-}"
    CHUTES_IDP_BASE_URL="${CHUTES_IDP_BASE_URL:-https://api.chutes.ai}"
    CHUTES_SSO_LOGIN_LABEL="${CHUTES_SSO_LOGIN_LABEL:-Login with Chutes}"
    CHUTES_SSO_SCOPES="${CHUTES_SSO_SCOPES:-$DEFAULT_CHUTES_SSO_SCOPES}"
    if [ "$CHUTES_SSO_SCOPES" = "$LEGACY_CHUTES_SSO_SCOPES" ]; then
        warn "Migrating legacy CHUTES_SSO_SCOPES to the current Chutes-supported default (email is not advertised by the live OIDC provider)"
        CHUTES_SSO_SCOPES="$DEFAULT_CHUTES_SSO_SCOPES"
    fi
    CHUTES_ADMIN_USERNAMES="${CHUTES_ADMIN_USERNAMES:-}"
    CHUTES_API_KEY="${CHUTES_API_KEY:-}"
    DROPZONE_HOST="${DROPZONE_HOST:-${N8N_HOST:-}}"
    N8N_ADMIN_EMAIL="${N8N_ADMIN_EMAIL:-admin@chutes.local}"
    OPENWEBUI_NAME="${OPENWEBUI_NAME:-Chutes Chat}"
    OPENWEBUI_ADMIN_NAME="${OPENWEBUI_ADMIN_NAME:-Chutes Chat Admin}"
    OPENWEBUI_ADMIN_EMAIL="${OPENWEBUI_ADMIN_EMAIL:-$N8N_ADMIN_EMAIL}"
    OPENWEBUI_API_BASE_URL="${OPENWEBUI_API_BASE_URL:-https://llm.chutes.ai/v1}"
    OPENWEBUI_API_KEY="${OPENWEBUI_API_KEY:-}"
    OPENWEBUI_MODELS_CACHE_TTL="${OPENWEBUI_MODELS_CACHE_TTL:-300}"
    OPENWEBUI_MODEL_ORDER_SYNC_INTERVAL="${OPENWEBUI_MODEL_ORDER_SYNC_INTERVAL:-300}"
    TZ="${TZ:-UTC}"

    # Load existing env if present (for --reconfigure preserving secrets)
    if [ -f "$ENV_FILE" ]; then
        load_env_file "$ENV_FILE"
    fi

    # --- Install mode ---
    if [ "$INSTALL_MODE" != "local" ] && [ "$INSTALL_MODE" != "domain" ]; then
        if [ "$INTERACTIVE" = true ]; then
            read_value _answer "Install mode [local/domain] (default: local): "
            case "${_answer:-local}" in
                local|LOCAL|l|L) INSTALL_MODE="local" ;;
                domain|DOMAIN|d|D) INSTALL_MODE="domain" ;;
                *) err "Install mode must be 'local' or 'domain'"; exit 1 ;;
            esac
        else
            INSTALL_MODE="${INSTALL_MODE:-local}"
        fi
    fi

    # --- Traffic mode ---
    if [ "$INTERACTIVE" = true ]; then
        echo
        echo "  Chutes model traffic:"
        echo "    direct      - use native Chutes endpoints (recommended)"
        echo "    e2ee-proxy  - route LLM text traffic through local e2ee-proxy"
        read_value _answer "  Choose traffic mode [direct/e2ee-proxy] (default: ${CHUTES_TRAFFIC_MODE}): "
        case "${_answer:-$CHUTES_TRAFFIC_MODE}" in
            direct|DIRECT|d|D) CHUTES_TRAFFIC_MODE="direct" ;;
            e2ee-proxy|proxy|p|P) CHUTES_TRAFFIC_MODE="e2ee-proxy" ;;
            *) err "Traffic mode must be 'direct' or 'e2ee-proxy'"; exit 1 ;;
        esac
    fi

    # --- TEE-only (e2ee-proxy only) ---
    if [ "$CHUTES_TRAFFIC_MODE" = "e2ee-proxy" ] && [ "$INTERACTIVE" = true ]; then
        echo
        echo "  e2ee-proxy confidentiality mode:"
        echo "    yes - keep proxy strictly TEE-only for text models"
        echo "    no  - allow non-TEE text models through proxy"
        read_value _answer "  Keep e2ee-proxy strictly TEE-only? [Y/n]: "
        case "${_answer:-yes}" in
            y|Y|yes|YES) ALLOW_NON_CONFIDENTIAL="false" ;;
            n|N|no|NO) ALLOW_NON_CONFIDENTIAL="true" ;;
            *) err "Please answer yes or no"; exit 1 ;;
        esac
    fi

    # --- SSO proxy bypass (e2ee-proxy only) ---
    CHUTES_SSO_PROXY_BYPASS="false"

    # --- Domain-specific settings ---
    if [ "$INSTALL_MODE" = "local" ]; then
        DROPZONE_HOST="$LOCAL_HOSTNAME"
        N8N_HOST="$DROPZONE_HOST"
        ACME_EMAIL=""
    else
        if [ "$INTERACTIVE" = true ]; then
            prompt_required DROPZONE_HOST "Public Dropzone hostname"
            prompt_required ACME_EMAIL "Let's Encrypt email"
        fi
        if [ -z "${DROPZONE_HOST:-}" ]; then
            err "DROPZONE_HOST is required for domain installs"
            exit 1
        fi
        N8N_HOST="$DROPZONE_HOST"
        if [ -z "${ACME_EMAIL:-}" ]; then
            err "ACME_EMAIL is required for domain installs"
            exit 1
        fi
    fi

    # --- Proxy URLs ---
    if [ "$CHUTES_TRAFFIC_MODE" = "e2ee-proxy" ]; then
        CHUTES_PROXY_BASE_URL="https://${DROPZONE_HOST}"
        CHUTES_CREDENTIAL_TEST_BASE_URL="https://${DROPZONE_HOST}"
        if [ "$INSTALL_MODE" = "domain" ]; then
            OPENWEBUI_API_BASE_URL="https://127.0.0.1:8443/v1"
        else
            OPENWEBUI_API_BASE_URL="https://${DROPZONE_HOST}/v1"
        fi
    else
        CHUTES_PROXY_BASE_URL=""
        CHUTES_CREDENTIAL_TEST_BASE_URL=""
    fi

    # --- OAuth credentials ---
    echo
    echo "  Create a Chutes app first:"
    echo "    https://chutes.ai/app/settings/apps"
    echo
    echo "  Suggested app fields:"
    echo "    App Name:     Chutes Dropzone"
    echo "    Description:  Sign in to your Chutes Dropzone workspace"
    echo "    Homepage URL: https://${DROPZONE_HOST}"
    if [ "$INSTALL_MODE" = "local" ]; then
        echo "    Redirect URI: https://${LOCAL_HOSTNAME}/oauth/oidc/callback"
        echo "                  https://${LOCAL_HOSTNAME}/rest/sso/chutes/callback"
        echo "                  since you are using it locally, use this"
    else
        echo "    Redirect URI: https://${DROPZONE_HOST}/oauth/oidc/callback"
        echo "                  https://${DROPZONE_HOST}/rest/sso/chutes/callback"
    fi
    echo
    echo "  Scopes to select:"
    echo "    OpenID"
    echo "    Email"
    echo "    Profile"
    echo "    Chutes Read"
    echo "    Chutes Invoke"
    echo
    echo "  Paste the Client ID and Client Secret below."
    if [ "$WIPE" = true ] && { [ -n "${CHUTES_OAUTH_CLIENT_ID:-}" ] || [ -n "${CHUTES_OAUTH_CLIENT_SECRET:-}" ]; }; then
        echo "  Wipe mode: press Enter to keep the current OAuth values or type replacements."
    fi
    prompt_required CHUTES_OAUTH_CLIENT_ID "Chutes OAuth Client ID" false "$WIPE"
    prompt_required CHUTES_OAUTH_CLIENT_SECRET "Chutes OAuth Client Secret" true "$WIPE"
    # --- Generate secrets (only if not already set) ---
    N8N_ENCRYPTION_KEY="${N8N_ENCRYPTION_KEY:-$(generate_hex 32)}"
    N8N_JWT_SECRET="${N8N_JWT_SECRET:-$(generate_hex 32)}"
    N8N_ADMIN_PASSWORD="${N8N_ADMIN_PASSWORD:-$(generate_owner_password)}"
    WEBUI_SECRET_KEY="${WEBUI_SECRET_KEY:-$(generate_hex 32)}"
    OPENWEBUI_ADMIN_PASSWORD="${OPENWEBUI_ADMIN_PASSWORD:-$(generate_owner_password)}"

    # --- Persist ---
    info "Writing configuration"
    write_env_file
    touch "$SENTINEL"
    ok "Configuration saved"
fi

# ---------------------------------------------------------------------------
# Derive runtime settings
# ---------------------------------------------------------------------------

DROPZONE_HOST="${DROPZONE_HOST:-${N8N_HOST:-$LOCAL_HOSTNAME}}"
N8N_HOST="${N8N_HOST:-$DROPZONE_HOST}"
OPENWEBUI_NAME="${OPENWEBUI_NAME:-Chutes Chat}"
OPENWEBUI_ADMIN_NAME="${OPENWEBUI_ADMIN_NAME:-Chutes Chat Admin}"
OPENWEBUI_ADMIN_EMAIL="${OPENWEBUI_ADMIN_EMAIL:-${N8N_ADMIN_EMAIL:-admin@chutes.local}}"
OPENWEBUI_API_BASE_URL="${OPENWEBUI_API_BASE_URL:-https://llm.chutes.ai/v1}"

# Database: external postgres if host is set, else sqlite
if [ -n "${DB_POSTGRESDB_HOST:-}" ]; then
    export DB_TYPE="postgresdb"
    export DB_POSTGRESDB_DATABASE="${DB_POSTGRESDB_DATABASE:-n8n}"
    export DB_POSTGRESDB_USER="${DB_POSTGRESDB_USER:-n8n}"
    export DB_POSTGRESDB_PORT="${DB_POSTGRESDB_PORT:-5432}"
else
    export DB_TYPE="sqlite"
fi

# n8n env vars
# n8n stores its runtime state under "${N8N_USER_FOLDER}/.n8n".
# Point it at /data so the effective state directory is /data/.n8n.
export N8N_USER_FOLDER="$DATA_DIR"
export N8N_ENCRYPTION_KEY
export N8N_USER_MANAGEMENT_JWT_SECRET="$N8N_JWT_SECRET"
export N8N_HOST="$DROPZONE_HOST"
export N8N_PORT=5678
export N8N_PROTOCOL=https
export N8N_EDITOR_BASE_URL="https://${DROPZONE_HOST}/n8n/"
export N8N_PATH="/n8n/"
export N8N_PROXY_HOPS=1
export N8N_SECURE_COOKIE=true
export WEBHOOK_URL="https://${DROPZONE_HOST}/n8n/"
export N8N_CUSTOM_EXTENSIONS=/opt/custom-nodes
export N8N_DIAGNOSTICS_ENABLED=false
export N8N_VERSION_NOTIFICATIONS_ENABLED=false
export N8N_RUNNERS_ENABLED=true
export N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=true
export N8N_EXPIRABLE_CREDENTIAL_REFRESH_WINDOW_SECONDS="${N8N_EXPIRABLE_CREDENTIAL_REFRESH_WINDOW_SECONDS:-300}"
export NODE_ENV=production

# Chutes env vars
export CHUTES_OAUTH_CLIENT_ID
export CHUTES_OAUTH_CLIENT_SECRET
export CHUTES_IDP_BASE_URL
export CHUTES_SSO_LOGIN_LABEL
export CHUTES_SSO_SCOPES
export CHUTES_SSO_CALLBACK_URL="https://${DROPZONE_HOST}/rest/sso/chutes/callback"
export CHUTES_ADMIN_USERNAMES
export CHUTES_TRAFFIC_MODE
export CHUTES_PROXY_BASE_URL
export CHUTES_CREDENTIAL_TEST_BASE_URL
export CHUTES_SSO_PROXY_BYPASS
export ALLOW_NON_CONFIDENTIAL
export CHUTES_API_KEY

# OpenWebUI env vars
export HOST=127.0.0.1
export PORT=8080
export WEBUI_URL="https://${DROPZONE_HOST}/chat"
export WEBUI_SECRET_KEY
export WEBUI_NAME="$OPENWEBUI_NAME"
export ADMIN_EMAIL="$OPENWEBUI_ADMIN_EMAIL"
export WEBUI_ADMIN_NAME="$OPENWEBUI_ADMIN_NAME"
export WEBUI_ADMIN_EMAIL="$OPENWEBUI_ADMIN_EMAIL"
export WEBUI_ADMIN_PASSWORD="$OPENWEBUI_ADMIN_PASSWORD"
export ENABLE_PERSISTENT_CONFIG=false
export ENABLE_OAUTH_PERSISTENT_CONFIG=false
export ENABLE_OAUTH_SIGNUP=true
export ENABLE_LOGIN_FORM=false
export ENABLE_PASSWORD_AUTH=false
export DEFAULT_USER_ROLE=user
export BYPASS_MODEL_ACCESS_CONTROL=true
export ENABLE_OAUTH_EMAIL_FALLBACK=true
export OAUTH_PROVIDER_NAME=Chutes
export OAUTH_CLIENT_ID="$CHUTES_OAUTH_CLIENT_ID"
export OAUTH_CLIENT_SECRET="$CHUTES_OAUTH_CLIENT_SECRET"
export OAUTH_SCOPES="$CHUTES_SSO_SCOPES"
export OAUTH_SUB_CLAIM=sub
export OAUTH_USERNAME_CLAIM=username
export OAUTH_EMAIL_CLAIM=email
export OPENID_PROVIDER_URL="${CHUTES_IDP_BASE_URL}/.well-known/openid-configuration"
export OPENID_REDIRECT_URI="https://${DROPZONE_HOST}/oauth/oidc/callback"
export OPENAI_API_BASE_URLS="$OPENWEBUI_API_BASE_URL"
export OPENAI_API_KEYS="${OPENWEBUI_API_KEY:-}"
export MODELS_CACHE_TTL="${OPENWEBUI_MODELS_CACHE_TTL:-300}"
export OPENWEBUI_MODEL_ORDER_SYNC_INTERVAL="${OPENWEBUI_MODEL_ORDER_SYNC_INTERVAL:-300}"
export OPENWEBUI_SYNC_BASE_URL="http://127.0.0.1:8080"

# Standalone mode markers (read by s6 service scripts and configure)
export STANDALONE_INSTALL_MODE="$INSTALL_MODE"
export STANDALONE_TRAFFIC_MODE="$CHUTES_TRAFFIC_MODE"
export STANDALONE_N8N_HOST="$DROPZONE_HOST"
export STANDALONE_DROPZONE_HOST="$DROPZONE_HOST"
export STANDALONE_ACME_EMAIL="${ACME_EMAIL:-}"
export STANDALONE_ADMIN_EMAIL="$N8N_ADMIN_EMAIL"
export STANDALONE_DATA_DIR="$DATA_DIR"
export STANDALONE_OPENWEBUI_DATA_DIR="$OPENWEBUI_STATE_DIR"

# Written to a file readable only by the configure oneshot, not the global env
printf '%s' "$N8N_ADMIN_PASSWORD" > /tmp/.owner-password
chmod 600 /tmp/.owner-password

# ---------------------------------------------------------------------------
# Render edge proxy configs
# ---------------------------------------------------------------------------
info "Rendering edge proxy configuration"

if [ "$INSTALL_MODE" = "local" ]; then
    TEMPLATE_SERVER_NAME="$DROPZONE_HOST" \
    TEMPLATE_RESOLVERS="8.8.8.8 8.8.4.4" \
    TEMPLATE_CHUTES_V1_BLOCK="$(nginx_chutes_v1_block)" \
    render_template_file /opt/standalone/nginx-standalone.conf.template /tmp/nginx-standalone.conf
    ok "nginx config rendered (local mode)"
fi

if [ "$INSTALL_MODE" = "domain" ]; then
    TEMPLATE_SERVER_NAME="$DROPZONE_HOST" \
    TEMPLATE_TLS_DIRECTIVE="tls ${ACME_EMAIL}" \
    TEMPLATE_CHUTES_V1_BLOCK="$(caddy_chutes_v1_block)" \
    render_template_file /opt/standalone/Caddyfile.template /tmp/Caddyfile
    ok "Caddyfile rendered (domain mode)"

    if [ "$CHUTES_TRAFFIC_MODE" = "e2ee-proxy" ]; then
        TEMPLATE_SERVER_NAME="$DROPZONE_HOST" \
        TEMPLATE_RESOLVERS="8.8.8.8 8.8.4.4" \
        render_template_file /opt/standalone/nginx-e2ee-internal.conf.template /tmp/nginx-e2ee-internal.conf
        ok "openresty e2ee config rendered (domain + e2ee-proxy)"
    fi
fi

# ---------------------------------------------------------------------------
# Hand off to s6-overlay
# ---------------------------------------------------------------------------
echo
info "Starting services (${INSTALL_MODE} + ${CHUTES_TRAFFIC_MODE})"
exec /init "$@"
