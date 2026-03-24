#!/usr/bin/env bash
#
# chutes-dropzone deploy
#
# Deployment entry point:
# - clones or refreshes the repo when launched outside an existing checkout
# - prompts for local vs domain deployment
# - captures the Chutes OAuth client credentials required for native SSO
# - renders the landing page and edge configs for /, /chat/, /n8n/, and optional /v1/*
# - builds the pinned n8n image with Chutes SSO overlay
# - boots postgres + n8n + OpenWebUI + the selected edge
# - provisions the n8n and OpenWebUI break-glass accounts
#
# Usage:
#   ./deploy.sh
#   ./deploy.sh --force
#   ./deploy.sh --wipe
#   ./deploy.sh --reset-owner-password
#   ./deploy.sh --force-all
#   ./deploy.sh --down
#
set -euo pipefail

REPO_REF="${CHUTES_DROPZONE_GIT_REF:-${CHUTES_N8N_LOCAL_GIT_REF:-${CHUTES_N8N_EMBED_GIT_REF:-main}}}"
REPO_URL="${CHUTES_DROPZONE_GIT_URL:-${CHUTES_N8N_LOCAL_GIT_URL:-${CHUTES_N8N_EMBED_GIT_URL:-https://github.com/chutesai/chutes-dropzone.git}}}"
INSTALL_DIR="${CHUTES_DROPZONE_DIR:-${CHUTES_N8N_LOCAL_DIR:-${CHUTES_N8N_EMBED_DIR:-$HOME/chutes-dropzone}}}"
SCRIPT_SOURCE="${BASH_SOURCE[0]:-$0}"
RUNNING_FROM_STDIN=false

case "$SCRIPT_SOURCE" in
    /dev/fd/*|/proc/self/fd/*|-|bash|-bash)
        RUNNING_FROM_STDIN=true
        ;;
esac

if SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_SOURCE")" >/dev/null 2>&1 && pwd)"; then
    :
else
    SCRIPT_DIR="$(pwd)"
fi

log() {
    printf '[deploy] %s\n' "$1"
}

in_repo_checkout() {
    [ "$RUNNING_FROM_STDIN" != true ] || return 1
    [ -f "$SCRIPT_DIR/docker-compose.yml" ] &&
    [ -f "$SCRIPT_DIR/Dockerfile.n8n" ] &&
    [ -d "$SCRIPT_DIR/scripts" ]
}

require_clone_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "$1 is required." >&2
        exit 1
    }
}

checkout_repo() {
    if [ -d "$INSTALL_DIR/.git" ]; then
        local dirty branch upstream

        dirty="$(git -C "$INSTALL_DIR" status --porcelain --untracked-files=no 2>/dev/null || true)"
        if [ -n "$dirty" ]; then
            log "existing checkout has local tracked changes; using it as-is"
            return
        fi

        branch="$(git -C "$INSTALL_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)"
        upstream="$(git -C "$INSTALL_DIR" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)"

        log "refreshing existing checkout in $INSTALL_DIR"
        git -C "$INSTALL_DIR" fetch --quiet origin || true
        git -C "$INSTALL_DIR" checkout "$REPO_REF" >/dev/null 2>&1 || true
        if [ -n "$upstream" ]; then
            git -C "$INSTALL_DIR" pull --ff-only --quiet || true
        elif [ "$branch" = "$REPO_REF" ]; then
            git -C "$INSTALL_DIR" pull --ff-only --quiet origin "$REPO_REF" || true
        fi
        return
    fi

    if [ -e "$INSTALL_DIR" ] && [ ! -d "$INSTALL_DIR/.git" ]; then
        echo "Install dir exists and is not a git checkout: $INSTALL_DIR" >&2
        exit 1
    fi

    mkdir -p "$(dirname "$INSTALL_DIR")"
    log "cloning $REPO_URL into $INSTALL_DIR"
    if git clone --depth 1 --branch "$REPO_REF" "$REPO_URL" "$INSTALL_DIR" >/dev/null 2>&1; then
        return
    fi

    log "shallow clone failed, retrying full checkout"
    rm -rf "$INSTALL_DIR"
    git clone "$REPO_URL" "$INSTALL_DIR" >/dev/null 2>&1
    git -C "$INSTALL_DIR" checkout "$REPO_REF" >/dev/null 2>&1
}

if ! in_repo_checkout; then
    require_clone_cmd git
    checkout_repo
    cd "$INSTALL_DIR"
    chmod +x ./deploy.sh
    log "running deploy from $INSTALL_DIR"
    if [ "$RUNNING_FROM_STDIN" = true ] && [ ! -t 0 ]; then
        cat >/dev/null || true
    fi
    exec ./deploy.sh "$@"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
LOCAL_HOSTNAME="e2ee-local-proxy.chutes.dev"
PROJECT_N8N_VERSION="2.12.1"
PROJECT_N8N_SOURCE_REPO="https://github.com/n8n-io/n8n.git"
PROJECT_N8N_SOURCE_SHA="42c7f71b6863581044006af0309ac38aab8d7c9f"
PROJECT_OPENWEBUI_VERSION="v0.8.10"
PROJECT_OPENWEBUI_IMAGE="ghcr.io/open-webui/open-webui:v0.8.10@sha256:7eb132b5f14905ef4b07872428681151b6a98e024132cdc9e8124119780e2261"
PROJECT_NODES_REPO="https://github.com/sirouk/n8n-nodes-chutes.git"
DEFAULT_CHUTES_SSO_SCOPES="openid profile chutes:read chutes:invoke"
LEGACY_CHUTES_SSO_SCOPES="openid email profile chutes:read chutes:invoke"
PROJECT_NODES_REF="d98eb1c02e966a99eb0c8ce66434feaa2c9049c3"
PROJECT_E2EE_PROXY_IMAGE="parachutes/e2ee-proxy:latest@sha256:0af4965c84e3eace05063fe2a013e818c30dd3687e9690a3bea83ae1df3b9a56"
PROJECT_CADDY_IMAGE="caddy:2.11.2-alpine@sha256:a1b7e624f860619cea121bdbc5dec2e112401666298c6507c6793b0a3ee6fc8e"
FORCE_ALL=false
RESET_OWNER_PASSWORD=false
DOWN=false
INTERACTIVE=false
TTY_DEVICE=""
INSTALL_ACTION="${INSTALL_ACTION:-}"
EXISTING_INSTALL=false
SKIP_BUILD="${SKIP_BUILD:-false}"
SKIP_APP_BUILDS="${SKIP_APP_BUILDS:-false}"

if [ -t 1 ] && [ -r /dev/tty ] && [ -w /dev/tty ]; then
    TTY_DEVICE="/dev/tty"
    INTERACTIVE=true
elif [ -t 0 ] && [ -t 1 ]; then
    INTERACTIVE=true
fi

for arg in "$@"; do
    case "$arg" in
        --force) INSTALL_ACTION="update" ;;
        --wipe) FORCE_ALL=true; INSTALL_ACTION="wipe" ;;
        --force-all) FORCE_ALL=true ;;
        --reset-owner-password) RESET_OWNER_PASSWORD=true ;;
        --down) DOWN=true ;;
        *)
            echo "Unknown argument: $arg" >&2
            exit 1
            ;;
    esac
done

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "${CYAN}[*]${NC} $*"; }
ok()    { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
err()   { echo -e "${RED}[x]${NC} $*" >&2; }

read_interactive_value() {
    local var_name="$1"
    local prompt="$2"
    local secret="${3:-false}"
    local _riv_value=""
    local tty_fd_opened=false

    if [ "$INTERACTIVE" != true ]; then
        err "$var_name must be set in non-interactive mode"
        exit 1
    fi

    if [ -n "$TTY_DEVICE" ]; then
        if exec 3<> "$TTY_DEVICE"; then
            tty_fd_opened=true
            printf '%s' "$prompt" >&3
            if [ "$secret" = true ]; then
                IFS= read -r -s -u 3 _riv_value || true
                printf '\n' >&3
            else
                IFS= read -r -u 3 _riv_value || true
            fi
            exec 3>&-
            exec 3<&-
        else
            warn "Unable to open ${TTY_DEVICE}; falling back to standard input for ${var_name}"
        fi
    fi

    if [ "$tty_fd_opened" != true ]; then
        if [ "$secret" = true ]; then
            read -rsp "$prompt" _riv_value || true
            echo
        else
            read -rp "$prompt" _riv_value || true
        fi
    fi

    _riv_value="${_riv_value%$'\r'}"
    printf -v "$var_name" '%s' "$_riv_value"
}

compose_files_default() {
    local install_mode="$1"
    local traffic_mode="${2:-${CHUTES_TRAFFIC_MODE:-direct}}"
    local files="docker-compose.yml"

    case "$install_mode" in
        local) files="${files}:docker-compose.local.yml" ;;
        domain) files="${files}:docker-compose.domain.yml" ;;
        *)
            err "Unsupported install mode: $install_mode"
            exit 1
            ;;
    esac

    case "$traffic_mode" in
        direct|"")
            ;;
        e2ee-proxy)
            if [ "$install_mode" = "domain" ]; then
                files="${files}:docker-compose.traffic-proxy.yml"
            fi
            ;;
        *)
            err "Unsupported Chutes traffic mode: $traffic_mode"
            exit 1
            ;;
    esac

    printf '%s' "$files"
}

compose_args() {
    local files="${CHUTES_COMPOSE_FILES:-$(compose_files_default "${INSTALL_MODE:-local}")}"
    local file
    local old_ifs="$IFS"
    local -a args=()

    IFS=':' read -r -a compose_files <<< "$files"
    IFS="$old_ifs"

    for file in "${compose_files[@]}"; do
        if [[ "$file" != /* ]]; then
            file="$SCRIPT_DIR/$file"
        fi
        args+=(-f "$file")
    done

    printf '%s\0' "${args[@]}"
}

compose() {
    local -a args=()
    while IFS= read -r -d '' arg; do
        args+=("$arg")
    done < <(compose_args)
    docker compose "${args[@]}" "$@"
}

compose_command_hint() {
    local files="${CHUTES_COMPOSE_FILES:-$(compose_files_default "${INSTALL_MODE:-local}")}"
    local file
    local out="docker compose"
    local old_ifs="$IFS"

    IFS=':' read -r -a compose_files <<< "$files"
    IFS="$old_ifs"

    for file in "${compose_files[@]}"; do
        if [[ "$file" != /* ]]; then
            file="$SCRIPT_DIR/$file"
        fi
        out="${out} -f ${file}"
    done

    printf '%s' "$out"
}

require_cmd() {
    local cmd="$1"
    command -v "$cmd" >/dev/null 2>&1 || {
        err "$cmd is required"
        exit 1
    }
}

remember_env_override() {
    local var_name="$1"
    local is_set_var="BOOTSTRAP_OVERRIDE_SET_${var_name}"
    local value_var="BOOTSTRAP_OVERRIDE_VALUE_${var_name}"

    if [ "${!var_name+x}" = x ]; then
        printf -v "$is_set_var" '%s' "true"
        printf -v "$value_var" '%s' "${!var_name}"
    else
        printf -v "$is_set_var" '%s' "false"
    fi
}

restore_env_override() {
    local var_name="$1"
    local is_set_var="BOOTSTRAP_OVERRIDE_SET_${var_name}"
    local value_var="BOOTSTRAP_OVERRIDE_VALUE_${var_name}"

    if [ "${!is_set_var:-false}" = "true" ]; then
        printf -v "$var_name" '%s' "${!value_var}"
        export "${var_name?}"
    fi
}

load_env_file() {
    set -a
    # shellcheck source=/dev/null
    source "$1"
    set +a
}

generate_hex() {
    local bytes="$1"
    openssl rand -hex "$bytes"
}

generate_owner_password() {
    local lower upper digits
    lower="$(openssl rand -hex 6 | tr 'A-F' 'a-f')"
    upper="$(openssl rand -hex 4 | tr 'a-f' 'A-F')"
    digits="$(openssl rand -hex 4 | tr -dc '0-9' | cut -c1-4)"

    while [ "${#digits}" -lt 4 ]; do
        digits="${digits}$(openssl rand -hex 1 | tr -dc '0-9')"
        digits="${digits:0:4}"
    done

    printf 'Ch%s%s%s' "$upper" "$lower" "$digits"
}

env_escape() {
    local value="$1"
    value="${value//$'\\'/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//\$/\\$}"
    value="${value//\`/\\\`}"
    printf '"%s"' "$value"
}

env_line() {
    printf '%s=%s\n' "$1" "$(env_escape "$2")"
}

is_proxy_backed_openwebui_url() {
    local value="${1%/}"

    case "$value" in
        https://llm.chutes.ai/v1)
            return 1
            ;;
        http://e2ee-proxy:80/v1|https://127.0.0.1:8443/v1)
            return 0
            ;;
        "https://${DROPZONE_HOST:-}/v1"|"https://${LOCAL_HOSTNAME}/v1")
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

render_template_file() {
    local template_path="$1"
    local output_path="$2"

    TEMPLATE_PATH="$template_path" OUTPUT_PATH="$output_path" python3 - <<'PY'
import os
from pathlib import Path

template = Path(os.environ["TEMPLATE_PATH"]).read_text(encoding="utf-8")
replacements = {
    "__SERVER_NAME__": os.environ.get("TEMPLATE_SERVER_NAME", ""),
    "__TLS_DIRECTIVE__": os.environ.get("TEMPLATE_TLS_DIRECTIVE", ""),
    "__RESOLVERS__": os.environ.get("TEMPLATE_RESOLVERS", ""),
    "__CHUTES_V1_BLOCK__": os.environ.get("TEMPLATE_CHUTES_V1_BLOCK", ""),
    "__ROOT_ENTRY_BLOCK__": os.environ.get("TEMPLATE_ROOT_ENTRY_BLOCK", ""),
    "__INSTALL_MODE__": os.environ.get("TEMPLATE_INSTALL_MODE", ""),
    "__CHUTES_TRAFFIC_MODE__": os.environ.get("TEMPLATE_CHUTES_TRAFFIC_MODE", ""),
    "__DROPZONE_HOST__": os.environ.get("TEMPLATE_DROPZONE_HOST", ""),
}

for placeholder, value in replacements.items():
    template = template.replace(placeholder, value)

Path(os.environ["OUTPUT_PATH"]).write_text(template, encoding="utf-8")
PY
}

caddy_chutes_v1_block() {
    if [ "$CHUTES_TRAFFIC_MODE" != "e2ee-proxy" ]; then
        cat <<'EOF'
    @chutes_v1 path /v1/*
    respond @chutes_v1 404

EOF
        return
    fi

    cat <<'EOF'
    @chutes_v1 path /v1/*
    reverse_proxy @chutes_v1 http://e2ee-proxy:80 {
        header_up Host e2ee-proxy
    }

EOF
}

nginx_chutes_v1_block() {
    if [ "$CHUTES_TRAFFIC_MODE" != "e2ee-proxy" ]; then
        cat <<'EOF'
        location /v1/ {
            return 404;
        }

EOF
        return
    fi

    cat <<'EOF'
        location /v1/ {
            if ($request_method = 'OPTIONS') {
                more_set_headers 'Access-Control-Allow-Origin: *';
                more_set_headers 'Access-Control-Allow-Methods: GET, POST, OPTIONS';
                more_set_headers 'Access-Control-Allow-Headers: *';
                more_set_headers 'Access-Control-Max-Age: 86400';
                more_set_headers 'Content-Length: 0';
                return 204;
            }

            more_set_headers 'Access-Control-Allow-Origin: *';
            more_set_headers 'Access-Control-Allow-Methods: GET, POST, OPTIONS';
            more_set_headers 'Access-Control-Allow-Headers: *';
            more_set_headers 'Access-Control-Expose-Headers: *';
            set $chutes_v1_host e2ee-proxy;
            set $chutes_v1_upstream http://$chutes_v1_host:80;
            proxy_pass $chutes_v1_upstream;
            proxy_http_version 1.1;
            proxy_set_header Host $chutes_v1_host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Host $host;
            proxy_set_header X-Forwarded-Proto https;
            proxy_read_timeout 600s;
            proxy_send_timeout 600s;
            client_max_body_size 10m;
        }

EOF
}

project_name() {
    printf '%s' "${COMPOSE_PROJECT_NAME:-$(basename "$SCRIPT_DIR")}"
}

existing_install_detected() {
    local compose_project
    compose_project="$(project_name)"

    if [ -f "$ENV_FILE" ]; then
        return 0
    fi

    if [ -n "$(compose ps -q n8n 2>/dev/null | head -n 1)" ]; then
        return 0
    fi

    if docker volume inspect "${compose_project}_n8n_data" >/dev/null 2>&1; then
        return 0
    fi

    if docker volume inspect "${compose_project}_openwebui_data" >/dev/null 2>&1; then
        return 0
    fi

    if docker volume inspect "${compose_project}_postgres_data" >/dev/null 2>&1; then
        return 0
    fi

    return 1
}

write_env_file() {
    {
        echo "# Auto-generated by deploy.sh — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo
        env_line INSTALL_MODE "$INSTALL_MODE"
        env_line CHUTES_TRAFFIC_MODE "$CHUTES_TRAFFIC_MODE"
        env_line DROPZONE_ENABLE_PUBLIC_LANDING "$DROPZONE_ENABLE_PUBLIC_LANDING"
        env_line CHUTES_COMPOSE_FILES "$CHUTES_COMPOSE_FILES"
        env_line EDGE_SERVICE "$EDGE_SERVICE"
        env_line E2EE_PROXY_IMAGE "$E2EE_PROXY_IMAGE"
        env_line CADDY_IMAGE "$CADDY_IMAGE"
        env_line ALLOW_NON_CONFIDENTIAL "$ALLOW_NON_CONFIDENTIAL"
        env_line CHUTES_SSO_PROXY_BYPASS "$CHUTES_SSO_PROXY_BYPASS"
        env_line CHUTES_PROXY_BASE_URL "$CHUTES_PROXY_BASE_URL"
        env_line CHUTES_CREDENTIAL_TEST_BASE_URL "$CHUTES_CREDENTIAL_TEST_BASE_URL"
        echo
        env_line N8N_VERSION "$N8N_VERSION"
        env_line N8N_SOURCE_REPO "$N8N_SOURCE_REPO"
        env_line N8N_SOURCE_REF "$N8N_SOURCE_REF"
        env_line N8N_SOURCE_SHA "$N8N_SOURCE_SHA"
        env_line OPENWEBUI_VERSION "$OPENWEBUI_VERSION"
        env_line OPENWEBUI_IMAGE "$OPENWEBUI_IMAGE"
        env_line TZ "$TZ"
        echo
        env_line DROPZONE_HOST "$DROPZONE_HOST"
        env_line N8N_HOST "$N8N_HOST"
        env_line ACME_EMAIL "$ACME_EMAIL"
        echo
        env_line POSTGRES_USER "$POSTGRES_USER"
        env_line POSTGRES_PASSWORD "$POSTGRES_PASSWORD"
        env_line POSTGRES_N8N_DB "$POSTGRES_N8N_DB"
        env_line POSTGRES_OPENWEBUI_DB "$POSTGRES_OPENWEBUI_DB"
        env_line POSTGRES_DB "$POSTGRES_DB"
        env_line POSTGRES_N8N_USER "$POSTGRES_N8N_USER"
        env_line POSTGRES_N8N_PASSWORD "$POSTGRES_N8N_PASSWORD"
        env_line POSTGRES_OPENWEBUI_USER "$POSTGRES_OPENWEBUI_USER"
        env_line POSTGRES_OPENWEBUI_PASSWORD "$POSTGRES_OPENWEBUI_PASSWORD"
        echo
        env_line N8N_ENCRYPTION_KEY "$N8N_ENCRYPTION_KEY"
        env_line N8N_JWT_SECRET "$N8N_JWT_SECRET"
        env_line N8N_ADMIN_EMAIL "$N8N_ADMIN_EMAIL"
        env_line N8N_ADMIN_PASSWORD "$N8N_ADMIN_PASSWORD"
        env_line N8N_EXPIRABLE_CREDENTIAL_REFRESH_WINDOW_SECONDS "$N8N_EXPIRABLE_CREDENTIAL_REFRESH_WINDOW_SECONDS"
        echo
        env_line WEBUI_SECRET_KEY "$WEBUI_SECRET_KEY"
        env_line OPENWEBUI_NAME "$OPENWEBUI_NAME"
        env_line OPENWEBUI_ADMIN_NAME "$OPENWEBUI_ADMIN_NAME"
        env_line OPENWEBUI_ADMIN_EMAIL "$OPENWEBUI_ADMIN_EMAIL"
        env_line OPENWEBUI_ADMIN_PASSWORD "$OPENWEBUI_ADMIN_PASSWORD"
        env_line OPENWEBUI_API_BASE_URL "$OPENWEBUI_API_BASE_URL"
        env_line OPENWEBUI_API_KEY "$OPENWEBUI_API_KEY"
        env_line OPENWEBUI_MODELS_CACHE_TTL "$OPENWEBUI_MODELS_CACHE_TTL"
        env_line OPENWEBUI_MODEL_ORDER_SYNC_INTERVAL "$OPENWEBUI_MODEL_ORDER_SYNC_INTERVAL"
        echo
        env_line CHUTES_OAUTH_CLIENT_ID "$CHUTES_OAUTH_CLIENT_ID"
        env_line CHUTES_OAUTH_CLIENT_SECRET "$CHUTES_OAUTH_CLIENT_SECRET"
        env_line CHUTES_IDP_BASE_URL "$CHUTES_IDP_BASE_URL"
        env_line CHUTES_SSO_LOGIN_LABEL "$CHUTES_SSO_LOGIN_LABEL"
        env_line CHUTES_SSO_SCOPES "$CHUTES_SSO_SCOPES"
        env_line CHUTES_ADMIN_USERNAMES "$CHUTES_ADMIN_USERNAMES"
        echo
        env_line CHUTES_API_KEY "$CHUTES_API_KEY"
    } > "$ENV_FILE"

    chmod 600 "$ENV_FILE"
}

caddy_root_entry_block() {
    if [ "${DROPZONE_ENABLE_PUBLIC_LANDING:-true}" = "false" ]; then
        cat <<'EOF'
    handle / {
        redir /c/new 302
    }

EOF
        return
    fi

    cat <<'EOF'
    handle / {
        header Cache-Control "no-store"
        root * /srv/landing
        rewrite * /index.html
        file_server
    }

EOF
}

nginx_root_entry_block() {
    if [ "${DROPZONE_ENABLE_PUBLIC_LANDING:-true}" = "false" ]; then
        cat <<'EOF'
        location = / {
            return 302 /c/new;
        }

EOF
        return
    fi

    cat <<'EOF'
        location = / {
            add_header Cache-Control "no-store" always;
            root /opt/landing;
            try_files /index.html =404;
        }

EOF
}

render_caddyfile() {
    TEMPLATE_SERVER_NAME="$DROPZONE_HOST" \
    TEMPLATE_TLS_DIRECTIVE="tls ${ACME_EMAIL}" \
    TEMPLATE_CHUTES_V1_BLOCK="$(caddy_chutes_v1_block)" \
    TEMPLATE_ROOT_ENTRY_BLOCK="$(caddy_root_entry_block)" \
    render_template_file "$SCRIPT_DIR/conf/Caddyfile.template" "$SCRIPT_DIR/conf/Caddyfile"
}

render_local_proxy_config() {
    TEMPLATE_SERVER_NAME="$DROPZONE_HOST" \
    TEMPLATE_RESOLVERS="127.0.0.11 8.8.8.8 8.8.4.4" \
    TEMPLATE_CHUTES_V1_BLOCK="$(nginx_chutes_v1_block)" \
    TEMPLATE_ROOT_ENTRY_BLOCK="$(nginx_root_entry_block)" \
    render_template_file \
        "$SCRIPT_DIR/conf/local-proxy.nginx.template" \
        "$SCRIPT_DIR/conf/local-proxy.nginx.conf"
}

render_landing_page() {
    TEMPLATE_INSTALL_MODE="$INSTALL_MODE" \
    TEMPLATE_CHUTES_TRAFFIC_MODE="$CHUTES_TRAFFIC_MODE" \
    TEMPLATE_DROPZONE_HOST="$DROPZONE_HOST" \
    render_template_file \
        "$SCRIPT_DIR/landing/index.template.html" \
        "$SCRIPT_DIR/landing/index.html"
}

container_runtime_status() {
    if [ -z "${1:-}" ]; then
        echo missing
        return
    fi

    docker inspect "$1" --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' 2>/dev/null || echo missing
}

compose_container_id() {
    compose ps -q "$1" 2>/dev/null | head -n 1
}

wait_for_service_ready() {
    local service="$1"
    local attempts="$2"
    local status="missing"
    local container=""

    while [ "$attempts" -gt 0 ]; do
        container="$(compose_container_id "$service")"
        status="$(container_runtime_status "$container")"
        if [ "$status" = "healthy" ] || [ "$status" = "running" ]; then
            printf '%s' "$status"
            return 0
        fi
        attempts=$((attempts - 1))
        sleep 2
    done

    printf '%s' "$status"
    return 1
}

remove_stale_edge_container() {
    local container
    local -a stale_containers=("n8n-nginx" "n8n-oauth2-proxy")

    case "$EDGE_SERVICE" in
        caddy) stale_containers+=("n8n-local-proxy") ;;
        local-proxy) stale_containers+=("n8n-caddy") ;;
    esac

    for container in "${stale_containers[@]}"; do
        if docker inspect "$container" >/dev/null 2>&1; then
            info "Removing stale ${container} ..."
            docker rm -f "$container" >/dev/null 2>&1 || true
        fi
    done
}

remove_stale_project_containers() {
    local compose_project
    local container_ids

    compose_project="$(project_name)"
    container_ids="$(docker ps -aq --filter "name=^/${compose_project}-")"

    if [ -z "$container_ids" ]; then
        return
    fi

    info "Removing stale ${compose_project} containers left behind by earlier runs ..."
    # shellcheck disable=SC2086
    docker rm -f $container_ids >/dev/null 2>&1 || true
}

check_owner_login() {
    local login_result
    login_result=$(compose exec -T n8n \
        wget -q -O- \
        --header='Content-Type: application/json' \
        --header='browser-id: bootstrap-check' \
        --post-data="$(printf '{"emailOrLdapLoginId":"%s","password":"%s"}' "$N8N_ADMIN_EMAIL" "$N8N_ADMIN_PASSWORD")" \
        http://127.0.0.1:5678/rest/login 2>/dev/null || true)
    [[ "$login_result" == *'"id"'* ]]
}

is_placeholder_client_id() {
    case "$1" in
        ""|test-chutes-client|dummy-client|example-client-id|changeme)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

is_placeholder_client_secret() {
    case "$1" in
        ""|test-secret|dummy-secret|changeme)
            return 0
            ;;
        *"test secret"*|*"example.invalid"*|*"changeme"*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

is_placeholder_email() {
    case "$1" in
        ""|ops@example.com|admin@example.com|e2e@example.invalid|example@example.com)
            return 0
            ;;
        *@example.com|*@example.invalid)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

is_test_idp_base_url() {
    case "$1" in
        "" )
            return 1
            ;;
        http://test-chutes-idp:8080|https://test-chutes-idp:8080)
            return 0
            ;;
        http://localhost:*|https://localhost:*|http://127.0.0.1:*|https://127.0.0.1:*)
            return 0
            ;;
        *test-chutes-idp*|*.invalid*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

validate_domain_hostname() {
    local host="$1"

    if [ -z "$host" ]; then
        err "DROPZONE_HOST is required for domain installs"
        exit 1
    fi

    if [ "$host" = "localhost" ] || [[ "$host" =~ ^[0-9.]+$ ]]; then
        err "Domain installs require a real FQDN, not '$host'"
        exit 1
    fi

    if [[ "$host" != *.* ]]; then
        err "DROPZONE_HOST must be a fully-qualified domain name"
        exit 1
    fi
}

validate_digest_pin() {
    local var_name="$1"
    local value="$2"

    case "$value" in
        *@sha256:*)
            ;;
        *)
            err "${var_name} must be pinned by digest"
            exit 1
            ;;
    esac
}

validate_versioned_digest_pin() {
    local var_name="$1"
    local version="$2"
    local image="$3"

    validate_digest_pin "$var_name" "$image"

    case "$image" in
        *":${version}@sha256:"*)
            ;;
        *)
            err "${var_name} must pin ${version} exactly (expected tag ${version} with a digest)"
            exit 1
            ;;
    esac
}

adopt_project_n8n_pin() {
    local desired_version="$PROJECT_N8N_VERSION"
    local desired_repo="$PROJECT_N8N_SOURCE_REPO"
    local desired_ref="n8n@${desired_version}"
    local desired_sha="$PROJECT_N8N_SOURCE_SHA"

    if [ "${BOOTSTRAP_OVERRIDE_SET_N8N_VERSION:-false}" != "true" ]; then
        if [ -n "${N8N_VERSION:-}" ] && [ "$N8N_VERSION" != "$desired_version" ]; then
            info "Project n8n pin advanced from ${N8N_VERSION} to ${desired_version}; updating the local install to match"
        fi
        N8N_VERSION="$desired_version"
    fi

    if [ "${BOOTSTRAP_OVERRIDE_SET_N8N_SOURCE_REPO:-false}" != "true" ]; then
        N8N_SOURCE_REPO="$desired_repo"
    fi

    if [ "${BOOTSTRAP_OVERRIDE_SET_N8N_SOURCE_REF:-false}" != "true" ]; then
        if [ "$N8N_SOURCE_REPO" = "$desired_repo" ]; then
            N8N_SOURCE_REF="$desired_ref"
        else
            N8N_SOURCE_REF="${N8N_SOURCE_REF:-n8n@${N8N_VERSION}}"
        fi
    fi

    if [ "${BOOTSTRAP_OVERRIDE_SET_N8N_SOURCE_SHA:-false}" != "true" ]; then
        if [ "$N8N_SOURCE_REPO" = "$desired_repo" ]; then
            N8N_SOURCE_SHA="$desired_sha"
        else
            N8N_SOURCE_SHA="${N8N_SOURCE_SHA:-}"
        fi
    fi
}

adopt_project_openwebui_pin() {
    local desired_version="$PROJECT_OPENWEBUI_VERSION"
    local desired_image="$PROJECT_OPENWEBUI_IMAGE"

    if [ "${BOOTSTRAP_OVERRIDE_SET_OPENWEBUI_VERSION:-false}" != "true" ]; then
        if [ -n "${OPENWEBUI_VERSION:-}" ] && [ "$OPENWEBUI_VERSION" != "$desired_version" ]; then
            info "Project OpenWebUI pin advanced from ${OPENWEBUI_VERSION} to ${desired_version}; updating the local install to match"
        fi
        OPENWEBUI_VERSION="$desired_version"
    fi

    if [ "${BOOTSTRAP_OVERRIDE_SET_OPENWEBUI_IMAGE:-false}" != "true" ]; then
        OPENWEBUI_IMAGE="$desired_image"
    fi
}

prompt_install_action() {
    local answer

    if [ "$EXISTING_INSTALL" != true ]; then
        INSTALL_ACTION="update"
        return
    fi

    if [ "$FORCE_ALL" = true ]; then
        INSTALL_ACTION="wipe"
        return
    fi

    if [ "$INSTALL_ACTION" = "update" ] || [ "$INSTALL_ACTION" = "wipe" ]; then
        return
    fi

    if [ "$INTERACTIVE" != true ]; then
        INSTALL_ACTION="update"
        info "Existing install detected; defaulting to update mode in non-interactive execution"
        return
    fi

    read_interactive_value answer "Existing install found. Action [update/wipe] (default: update): "

    case "${answer:-update}" in
        update|UPDATE|Update|u|U) INSTALL_ACTION="update" ;;
        wipe|WIPE|Wipe|w|W) INSTALL_ACTION="wipe" ;;
        *)
            err "Install action must be 'update' or 'wipe'"
            exit 1
            ;;
    esac
}

refresh_local_dependency_checkout() {
    local repo_dir="$1"
    local repo_name requested_ref target_ref target_head current_head

    repo_name="$(basename "$repo_dir")"

    if [ ! -d "$repo_dir/.git" ]; then
        info "Using local ${repo_name} directory (not a git checkout)"
        return
    fi

    if ! command -v git >/dev/null 2>&1; then
        warn "git is not installed; using current ${repo_name} checkout without refreshing"
        return
    fi

    requested_ref="${PROJECT_NODES_REF:-main}"

    info "Fetching latest ${repo_name} from origin ..."
    if ! git -C "$repo_dir" fetch --quiet origin; then
        warn "Failed to fetch updates for ${repo_name}; using the current checkout"
        return
    fi

    if [[ "$requested_ref" =~ ^[0-9a-fA-F]{7,40}$ ]]; then
        target_ref="$requested_ref"
    else
        target_ref="origin/$requested_ref"
    fi

    target_head="$(git -C "$repo_dir" rev-parse "${target_ref}^{commit}" 2>/dev/null || true)"
    if [ -z "$target_head" ]; then
        warn "Could not resolve ${target_ref} for ${repo_name}; using the current checkout"
        return
    fi

    current_head="$(git -C "$repo_dir" rev-parse HEAD 2>/dev/null || true)"
    if [ "$current_head" = "$target_head" ]; then
        ok "${repo_name} is already up to date"
        return
    fi

    info "Resetting ${repo_name} to ${target_ref} ..."
    if git -C "$repo_dir" checkout --quiet --force --detach "$target_head" 2>/dev/null; then
        ok "${repo_name} updated to $(git -C "$repo_dir" rev-parse --short HEAD)"
    else
        warn "Could not reset ${repo_name} to ${target_ref}; using the current checkout"
    fi
}

ensure_dependency_checkout() {
    local repo_dir="$1"
    local repo_url="$2"
    local repo_ref="$3"
    local repo_name
    local tmp_dir

    repo_name="$(basename "$repo_dir")"

    if [ -d "$repo_dir" ]; then
        return
    fi

    require_cmd git

    mkdir -p "$(dirname "$repo_dir")"
    tmp_dir="${repo_dir}.tmp.$$"
    rm -rf "$tmp_dir"

    info "${repo_name} not found; cloning ${repo_url} (${repo_ref}) ..."

    if git clone --depth 1 --branch "$repo_ref" "$repo_url" "$tmp_dir" >/dev/null 2>&1; then
        mv "$tmp_dir" "$repo_dir"
        ok "${repo_name} cloned"
        return
    fi

    warn "Shallow clone for ${repo_name} failed; retrying with a full checkout"
    rm -rf "$tmp_dir"

    if git clone "$repo_url" "$tmp_dir" >/dev/null 2>&1 && git -C "$tmp_dir" checkout "$repo_ref" >/dev/null 2>&1; then
        mv "$tmp_dir" "$repo_dir"
        ok "${repo_name} cloned"
        return
    fi

    rm -rf "$tmp_dir"
    err "Failed to clone ${repo_name} from ${repo_url}"
    exit 1
}

prompt_install_mode() {
    local answer

    if [ "${INSTALL_MODE:-}" = "local" ] || [ "${INSTALL_MODE:-}" = "domain" ]; then
        return
    fi

    if [ "$INTERACTIVE" != true ]; then
        err "INSTALL_MODE must be set to 'local' or 'domain' in non-interactive mode"
        exit 1
    fi

    read_interactive_value answer "Install mode [local/domain] (default: local): "

    case "${answer:-local}" in
        local|LOCAL|Local|l|L) INSTALL_MODE="local" ;;
        domain|DOMAIN|Domain|d|D) INSTALL_MODE="domain" ;;
        *)
            err "Install mode must be 'local' or 'domain'"
            exit 1
            ;;
    esac
}

prompt_traffic_mode() {
    local answer
    local default_mode="direct"

    if [ "${BOOTSTRAP_OVERRIDE_SET_CHUTES_TRAFFIC_MODE:-false}" = "true" ]; then
        default_mode="$CHUTES_TRAFFIC_MODE"
    elif [ "$EXISTING_INSTALL" = true ] && [ "${INSTALL_ACTION:-update}" = "update" ]; then
        default_mode="${CHUTES_TRAFFIC_MODE:-direct}"
    fi

    case "$default_mode" in
        direct|e2ee-proxy)
            ;;
        *)
            default_mode="direct"
            ;;
    esac

    if [ "$INTERACTIVE" != true ]; then
        CHUTES_TRAFFIC_MODE="$default_mode"
        return
    fi

    echo
    echo "  Chutes model traffic:"
    echo "    direct      - use native Chutes endpoints (recommended, keeps Chutes routing/failover behavior)"
    echo "    e2ee-proxy  - route OpenAI-compatible LLM text traffic through the local e2ee-proxy path"
    if [ "$INSTALL_MODE" = "local" ]; then
        echo "  Note: local installs still use the embedded e2ee-proxy certificate path for serving n8n itself."
    fi
    read_interactive_value answer "  Choose traffic mode [direct/e2ee-proxy] (default: ${default_mode}): "

    case "${answer:-$default_mode}" in
        direct|DIRECT|Direct|d|D) CHUTES_TRAFFIC_MODE="direct" ;;
        e2ee-proxy|E2EE-PROXY|E2ee-proxy|proxy|PROXY|Proxy|p|P) CHUTES_TRAFFIC_MODE="e2ee-proxy" ;;
        *)
            err "Chutes traffic mode must be 'direct' or 'e2ee-proxy'"
            exit 1
            ;;
    esac
}

prompt_public_landing() {
    local answer
    local default_answer="yes"

    if [ "${BOOTSTRAP_OVERRIDE_SET_DROPZONE_ENABLE_PUBLIC_LANDING:-false}" = "true" ]; then
        if [ "${DROPZONE_ENABLE_PUBLIC_LANDING:-true}" = "false" ]; then
            default_answer="no"
        fi
    elif [ "$EXISTING_INSTALL" = true ]; then
        if [ "${DROPZONE_ENABLE_PUBLIC_LANDING:-true}" = "false" ]; then
            default_answer="no"
        fi
    fi

    if [ "$INTERACTIVE" != true ]; then
        if [ "$default_answer" = "yes" ]; then
            DROPZONE_ENABLE_PUBLIC_LANDING="true"
        else
            DROPZONE_ENABLE_PUBLIC_LANDING="false"
        fi
        return
    fi

    echo
    echo "  Root entry behavior:"
    echo "    yes - keep the public launcher at /"
    echo "    no  - redirect / straight to /chat/"
    if [ "$default_answer" = "yes" ]; then
        read_interactive_value answer "  Enable the public landing page? [Y/n]: "
    else
        read_interactive_value answer "  Enable the public landing page? [y/N]: "
    fi

    case "${answer:-$default_answer}" in
        y|Y|yes|YES|Yes)
            DROPZONE_ENABLE_PUBLIC_LANDING="true"
            ;;
        n|N|no|NO|No)
            DROPZONE_ENABLE_PUBLIC_LANDING="false"
            ;;
        *)
            err "Please answer yes or no"
            exit 1
            ;;
    esac
}

prompt_e2ee_proxy_confidential_mode() {
    local answer
    local default_answer="yes"

    if [ "$CHUTES_TRAFFIC_MODE" != "e2ee-proxy" ]; then
        return
    fi

    if [ "${BOOTSTRAP_OVERRIDE_SET_ALLOW_NON_CONFIDENTIAL:-false}" = "true" ]; then
        if [ "${ALLOW_NON_CONFIDENTIAL:-false}" = "true" ]; then
            default_answer="no"
        fi
    elif [ "$EXISTING_INSTALL" = true ] && [ "${INSTALL_ACTION:-update}" = "update" ]; then
        if [ "${ALLOW_NON_CONFIDENTIAL:-false}" = "true" ]; then
            default_answer="no"
        fi
    fi

    if [ "$INTERACTIVE" != true ]; then
        if [ "$default_answer" = "yes" ]; then
            ALLOW_NON_CONFIDENTIAL="false"
        else
            ALLOW_NON_CONFIDENTIAL="true"
        fi
        return
    fi

    echo
    echo "  e2ee-proxy confidentiality mode:"
    echo "    yes - keep the proxy path strict TEE-only for text models"
    echo "    no  - allow non-TEE text models through the proxy path too"
    if [ "$default_answer" = "yes" ]; then
        read_interactive_value answer "  Keep e2ee-proxy strictly TEE-only? [Y/n]: "
    else
        read_interactive_value answer "  Keep e2ee-proxy strictly TEE-only? [y/N]: "
    fi

    case "${answer:-$default_answer}" in
        y|Y|yes|YES|Yes)
            ALLOW_NON_CONFIDENTIAL="false"
            ;;
        n|N|no|NO|No)
            ALLOW_NON_CONFIDENTIAL="true"
            ;;
        *)
            err "Please answer yes or no"
            exit 1
            ;;
    esac
}

normalize_sso_proxy_bypass() {
    local default_bypass="false"

    if [ "$CHUTES_TRAFFIC_MODE" != "e2ee-proxy" ]; then
        CHUTES_SSO_PROXY_BYPASS="false"
        return
    fi

    if [ "${BOOTSTRAP_OVERRIDE_SET_CHUTES_SSO_PROXY_BYPASS:-false}" = "true" ]; then
        case "${CHUTES_SSO_PROXY_BYPASS:-$default_bypass}" in
            true|false)
                ;;
            *)
                err "CHUTES_SSO_PROXY_BYPASS must be 'true' or 'false'"
                exit 1
                ;;
        esac
        return
    fi

    if [ "$EXISTING_INSTALL" = true ] && [ "${INSTALL_ACTION:-update}" = "update" ]; then
        case "${CHUTES_SSO_PROXY_BYPASS:-$default_bypass}" in
            true|false)
                if [ "${CHUTES_SSO_PROXY_BYPASS:-$default_bypass}" = "true" ]; then
                    warn "Disabling legacy CHUTES_SSO_PROXY_BYPASS so n8n SSO text traffic stays on e2ee-proxy."
                    CHUTES_SSO_PROXY_BYPASS="$default_bypass"
                fi
                ;;
            *)
                CHUTES_SSO_PROXY_BYPASS="$default_bypass"
                ;;
        esac
        return
    fi

    CHUTES_SSO_PROXY_BYPASS="$default_bypass"
}

prompt_required_value() {
    local var_name="$1"
    local prompt="$2"
    local secret="${3:-false}"
    local prompt_existing="${4:-false}"
    local current="${!var_name:-}"
    local value=""

    if [ -n "$current" ] && { [ "$prompt_existing" != true ] || [ "$INTERACTIVE" != true ]; }; then
        return
    fi

    if [ -n "$current" ] && [ "$prompt_existing" = true ]; then
        if [ "$secret" = true ]; then
            read_interactive_value value "  ${prompt} [press Enter to keep current value]: " true
        else
            read_interactive_value value "  ${prompt} [${current}]: " false
        fi
        if [ -z "$value" ]; then
            value="$current"
        fi
    else
        read_interactive_value value "  ${prompt}: " "$secret"
    fi

    if [ -z "$value" ]; then
        err "$var_name must not be empty"
        exit 1
    fi

    printf -v "$var_name" '%s' "$value"
}

ensure_real_chutes_oauth_credentials() {
    local prompt_existing_oauth=false

    if [ "${BOOTSTRAP_OVERRIDE_SET_CHUTES_IDP_BASE_URL:-false}" != "true" ] && \
        is_test_idp_base_url "${CHUTES_IDP_BASE_URL:-}"; then
        warn "Ignoring test-only CHUTES_IDP_BASE_URL=${CHUTES_IDP_BASE_URL} for a real deploy run"
        CHUTES_IDP_BASE_URL="https://api.chutes.ai"
        CHUTES_OAUTH_CLIENT_ID=""
        CHUTES_OAUTH_CLIENT_SECRET=""
    fi

    if [ "${CHUTES_IDP_BASE_URL:-https://api.chutes.ai}" = "https://api.chutes.ai" ]; then
        if is_placeholder_client_id "${CHUTES_OAUTH_CLIENT_ID:-}"; then
            CHUTES_OAUTH_CLIENT_ID=""
        fi

        if is_placeholder_client_secret "${CHUTES_OAUTH_CLIENT_SECRET:-}"; then
            CHUTES_OAUTH_CLIENT_SECRET=""
        fi
    fi

    echo
    echo "  Create a Chutes app first:"
    echo "    https://chutes.ai/app/settings/apps"
    echo
    echo "  Suggested app fields:"
    echo "    App Name:     Chutes Dropzone"
    echo "    Description:  Sign in to your Chutes Dropzone workspace"
    echo "    Homepage URL: https://${DROPZONE_HOST}"
    if [ "$INSTALL_MODE" = "local" ]; then
        echo "    Redirect URI: https://${LOCAL_HOSTNAME}/rest/sso/chutes/callback"
        echo "                  https://${LOCAL_HOSTNAME}/oauth/oidc/callback"
        echo "                  since you are using it locally, use this exact host"
    else
        echo "    Redirect URI: https://${DROPZONE_HOST}/rest/sso/chutes/callback"
        echo "                  https://${DROPZONE_HOST}/oauth/oidc/callback"
    fi
    echo
    echo "  Scopes to select:"
    echo "    OpenID"
    echo "    Profile"
    echo "    Chutes Read"
    echo "    Chutes Invoke"
    echo
    echo "  Paste the Client ID and Client Secret below."
    if [ "$EXISTING_INSTALL" = true ] && [ "${INSTALL_ACTION:-update}" = "wipe" ] && \
        { [ -n "${CHUTES_OAUTH_CLIENT_ID:-}" ] || [ -n "${CHUTES_OAUTH_CLIENT_SECRET:-}" ]; }; then
        echo "  Wipe mode: press Enter to keep the current OAuth values or type replacements."
        prompt_existing_oauth=true
    fi

    prompt_required_value CHUTES_OAUTH_CLIENT_ID "Chutes OAuth Client ID" false "$prompt_existing_oauth"
    prompt_required_value CHUTES_OAUTH_CLIENT_SECRET "Chutes OAuth Client Secret" true "$prompt_existing_oauth"
}

for overridable_var in \
    INSTALL_MODE \
    CHUTES_TRAFFIC_MODE \
    DROPZONE_ENABLE_PUBLIC_LANDING \
    CHUTES_COMPOSE_FILES \
    EDGE_SERVICE \
    E2EE_PROXY_IMAGE \
    CADDY_IMAGE \
    ALLOW_NON_CONFIDENTIAL \
    CHUTES_SSO_PROXY_BYPASS \
    CHUTES_PROXY_BASE_URL \
    CHUTES_CREDENTIAL_TEST_BASE_URL \
    N8N_VERSION \
    N8N_SOURCE_REPO \
    N8N_SOURCE_REF \
    N8N_SOURCE_SHA \
    OPENWEBUI_VERSION \
    OPENWEBUI_IMAGE \
    TZ \
    DROPZONE_HOST \
    N8N_HOST \
    ACME_EMAIL \
    POSTGRES_USER \
    POSTGRES_PASSWORD \
    POSTGRES_N8N_DB \
    POSTGRES_OPENWEBUI_DB \
    POSTGRES_DB \
    POSTGRES_N8N_USER \
    POSTGRES_N8N_PASSWORD \
    POSTGRES_OPENWEBUI_USER \
    POSTGRES_OPENWEBUI_PASSWORD \
    N8N_ENCRYPTION_KEY \
    N8N_JWT_SECRET \
    N8N_ADMIN_EMAIL \
    N8N_ADMIN_PASSWORD \
    N8N_EXPIRABLE_CREDENTIAL_REFRESH_WINDOW_SECONDS \
    WEBUI_SECRET_KEY \
    OPENWEBUI_NAME \
    OPENWEBUI_ADMIN_NAME \
    OPENWEBUI_ADMIN_EMAIL \
    OPENWEBUI_ADMIN_PASSWORD \
    OPENWEBUI_API_BASE_URL \
    OPENWEBUI_API_KEY \
    OPENWEBUI_MODELS_CACHE_TTL \
    OPENWEBUI_MODEL_ORDER_SYNC_INTERVAL \
    CHUTES_OAUTH_CLIENT_ID \
    CHUTES_OAUTH_CLIENT_SECRET \
    CHUTES_IDP_BASE_URL \
    CHUTES_SSO_LOGIN_LABEL \
    CHUTES_SSO_SCOPES \
    CHUTES_ADMIN_USERNAMES \
    CHUTES_API_KEY
do
    remember_env_override "$overridable_var"
done

if [ -f "$ENV_FILE" ]; then
    load_env_file "$ENV_FILE"
fi

for overridable_var in \
    INSTALL_MODE \
    CHUTES_TRAFFIC_MODE \
    DROPZONE_ENABLE_PUBLIC_LANDING \
    CHUTES_COMPOSE_FILES \
    EDGE_SERVICE \
    E2EE_PROXY_IMAGE \
    CADDY_IMAGE \
    ALLOW_NON_CONFIDENTIAL \
    CHUTES_SSO_PROXY_BYPASS \
    CHUTES_PROXY_BASE_URL \
    CHUTES_CREDENTIAL_TEST_BASE_URL \
    N8N_VERSION \
    N8N_SOURCE_REPO \
    N8N_SOURCE_REF \
    N8N_SOURCE_SHA \
    OPENWEBUI_VERSION \
    OPENWEBUI_IMAGE \
    TZ \
    DROPZONE_HOST \
    N8N_HOST \
    ACME_EMAIL \
    POSTGRES_USER \
    POSTGRES_PASSWORD \
    POSTGRES_N8N_DB \
    POSTGRES_OPENWEBUI_DB \
    POSTGRES_DB \
    POSTGRES_N8N_USER \
    POSTGRES_N8N_PASSWORD \
    POSTGRES_OPENWEBUI_USER \
    POSTGRES_OPENWEBUI_PASSWORD \
    N8N_ENCRYPTION_KEY \
    N8N_JWT_SECRET \
    N8N_ADMIN_EMAIL \
    N8N_ADMIN_PASSWORD \
    N8N_EXPIRABLE_CREDENTIAL_REFRESH_WINDOW_SECONDS \
    WEBUI_SECRET_KEY \
    OPENWEBUI_NAME \
    OPENWEBUI_ADMIN_NAME \
    OPENWEBUI_ADMIN_EMAIL \
    OPENWEBUI_ADMIN_PASSWORD \
    OPENWEBUI_API_BASE_URL \
    OPENWEBUI_API_KEY \
    OPENWEBUI_MODELS_CACHE_TTL \
    OPENWEBUI_MODEL_ORDER_SYNC_INTERVAL \
    CHUTES_OAUTH_CLIENT_ID \
    CHUTES_OAUTH_CLIENT_SECRET \
    CHUTES_IDP_BASE_URL \
    CHUTES_SSO_LOGIN_LABEL \
    CHUTES_SSO_SCOPES \
    CHUTES_ADMIN_USERNAMES \
    CHUTES_API_KEY
do
    restore_env_override "$overridable_var"
done

N8N_VERSION="${N8N_VERSION:-$PROJECT_N8N_VERSION}"
N8N_SOURCE_REPO="${N8N_SOURCE_REPO:-$PROJECT_N8N_SOURCE_REPO}"
N8N_SOURCE_REF="${N8N_SOURCE_REF:-n8n@${N8N_VERSION}}"
N8N_SOURCE_SHA="${N8N_SOURCE_SHA:-$PROJECT_N8N_SOURCE_SHA}"
OPENWEBUI_VERSION="${OPENWEBUI_VERSION:-$PROJECT_OPENWEBUI_VERSION}"
OPENWEBUI_IMAGE="${OPENWEBUI_IMAGE:-$PROJECT_OPENWEBUI_IMAGE}"
TZ="${TZ:-UTC}"
DROPZONE_HOST="${DROPZONE_HOST:-${N8N_HOST:-}}"
N8N_HOST="${N8N_HOST:-$DROPZONE_HOST}"
POSTGRES_USER="${POSTGRES_USER:-dropzone}"
POSTGRES_N8N_DB="${POSTGRES_N8N_DB:-${POSTGRES_DB:-n8n}}"
POSTGRES_OPENWEBUI_DB="${POSTGRES_OPENWEBUI_DB:-openwebui}"
POSTGRES_DB="${POSTGRES_DB:-$POSTGRES_N8N_DB}"
N8N_ADMIN_EMAIL="${N8N_ADMIN_EMAIL:-admin@chutes.local}"
N8N_EXPIRABLE_CREDENTIAL_REFRESH_WINDOW_SECONDS="${N8N_EXPIRABLE_CREDENTIAL_REFRESH_WINDOW_SECONDS:-300}"
OPENWEBUI_NAME="${OPENWEBUI_NAME:-Chutes Chat}"
OPENWEBUI_ADMIN_NAME="${OPENWEBUI_ADMIN_NAME:-Dropzone Service Account}"
OPENWEBUI_ADMIN_EMAIL="${OPENWEBUI_ADMIN_EMAIL:-svc-dropzone@internal.chutes.local}"
OPENWEBUI_API_BASE_URL="${OPENWEBUI_API_BASE_URL:-https://llm.chutes.ai/v1}"
OPENWEBUI_API_KEY="${OPENWEBUI_API_KEY:-}"
OPENWEBUI_MODELS_CACHE_TTL="${OPENWEBUI_MODELS_CACHE_TTL:-300}"
OPENWEBUI_MODEL_ORDER_SYNC_INTERVAL="${OPENWEBUI_MODEL_ORDER_SYNC_INTERVAL:-300}"
CHUTES_IDP_BASE_URL="${CHUTES_IDP_BASE_URL:-https://api.chutes.ai}"
CHUTES_SSO_LOGIN_LABEL="${CHUTES_SSO_LOGIN_LABEL:-Login with Chutes}"
CHUTES_SSO_SCOPES="${CHUTES_SSO_SCOPES:-$DEFAULT_CHUTES_SSO_SCOPES}"
if [ "$CHUTES_SSO_SCOPES" = "$LEGACY_CHUTES_SSO_SCOPES" ]; then
    warn "Migrating legacy CHUTES_SSO_SCOPES to the current Chutes-supported default (email is not advertised by the live OIDC provider)"
    CHUTES_SSO_SCOPES="$DEFAULT_CHUTES_SSO_SCOPES"
fi
CHUTES_ADMIN_USERNAMES="${CHUTES_ADMIN_USERNAMES:-}"
CHUTES_API_KEY="${CHUTES_API_KEY:-}"
CHUTES_TRAFFIC_MODE="${CHUTES_TRAFFIC_MODE:-direct}"
DROPZONE_ENABLE_PUBLIC_LANDING="${DROPZONE_ENABLE_PUBLIC_LANDING:-true}"
E2EE_PROXY_IMAGE="${E2EE_PROXY_IMAGE:-$PROJECT_E2EE_PROXY_IMAGE}"
CADDY_IMAGE="${CADDY_IMAGE:-$PROJECT_CADDY_IMAGE}"
ALLOW_NON_CONFIDENTIAL="${ALLOW_NON_CONFIDENTIAL:-false}"
CHUTES_SSO_PROXY_BYPASS="${CHUTES_SSO_PROXY_BYPASS:-false}"
CHUTES_PROXY_BASE_URL="${CHUTES_PROXY_BASE_URL:-}"
CHUTES_CREDENTIAL_TEST_BASE_URL="${CHUTES_CREDENTIAL_TEST_BASE_URL:-}"
INSTALL_MODE="${INSTALL_MODE:-}"
ACME_EMAIL="${ACME_EMAIL:-}"

adopt_project_n8n_pin
adopt_project_openwebui_pin
validate_versioned_digest_pin "OPENWEBUI_IMAGE" "$OPENWEBUI_VERSION" "$OPENWEBUI_IMAGE"
validate_digest_pin "E2EE_PROXY_IMAGE" "$E2EE_PROXY_IMAGE"
validate_digest_pin "CADDY_IMAGE" "$CADDY_IMAGE"

if [ "$DOWN" = true ] && [ -z "$INSTALL_MODE" ]; then
    INSTALL_MODE="local"
fi

if [ "$FORCE_ALL" = true ]; then
    warn "--force-all will rotate data secrets and destroy existing docker volumes for this stack"
fi

prompt_install_mode
if existing_install_detected; then
    EXISTING_INSTALL=true
fi
prompt_public_landing
prompt_install_action
prompt_traffic_mode
prompt_e2ee_proxy_confidential_mode
normalize_sso_proxy_bypass

if [ "$INSTALL_ACTION" = "wipe" ] && [ "$FORCE_ALL" != true ]; then
    FORCE_ALL=true
fi

if [ "$INSTALL_MODE" = "local" ]; then
    if [ -n "${DROPZONE_HOST:-}" ] && [ "$DROPZONE_HOST" != "$LOCAL_HOSTNAME" ]; then
        warn "Local installs always use ${LOCAL_HOSTNAME}; overriding DROPZONE_HOST=${DROPZONE_HOST}"
    fi
    DROPZONE_HOST="$LOCAL_HOSTNAME"
    N8N_HOST="$DROPZONE_HOST"
    ACME_EMAIL=""
    if [ "${BOOTSTRAP_OVERRIDE_SET_CHUTES_COMPOSE_FILES:-false}" != "true" ]; then
        CHUTES_COMPOSE_FILES="$(compose_files_default local "$CHUTES_TRAFFIC_MODE")"
    fi
    if [ "${BOOTSTRAP_OVERRIDE_SET_EDGE_SERVICE:-false}" != "true" ]; then
        EDGE_SERVICE="local-proxy"
    fi
    if [ "$CHUTES_TRAFFIC_MODE" = "e2ee-proxy" ]; then
        CHUTES_PROXY_BASE_URL="https://${DROPZONE_HOST}"
        CHUTES_CREDENTIAL_TEST_BASE_URL="https://${DROPZONE_HOST}"
        OPENWEBUI_API_BASE_URL="https://${DROPZONE_HOST}/v1"
    else
        CHUTES_PROXY_BASE_URL=""
        CHUTES_CREDENTIAL_TEST_BASE_URL=""
        if [ "${BOOTSTRAP_OVERRIDE_SET_OPENWEBUI_API_BASE_URL:-false}" != "true" ] && \
            { [ -z "${OPENWEBUI_API_BASE_URL:-}" ] || is_proxy_backed_openwebui_url "$OPENWEBUI_API_BASE_URL"; }; then
            OPENWEBUI_API_BASE_URL="https://llm.chutes.ai/v1"
        fi
    fi
else
    if [ -z "${DROPZONE_HOST:-}" ] && [ "$INTERACTIVE" = true ]; then
        read_interactive_value DROPZONE_HOST "  Public Dropzone hostname: "
    fi

    if is_placeholder_email "${ACME_EMAIL:-}"; then
        ACME_EMAIL=""
    fi

    prompt_required_value DROPZONE_HOST "Public Dropzone hostname"
    N8N_HOST="$DROPZONE_HOST"
    prompt_required_value ACME_EMAIL "Let's Encrypt email"
    validate_domain_hostname "$DROPZONE_HOST"

    if [ "${BOOTSTRAP_OVERRIDE_SET_CHUTES_COMPOSE_FILES:-false}" != "true" ]; then
        CHUTES_COMPOSE_FILES="$(compose_files_default domain "$CHUTES_TRAFFIC_MODE")"
    fi
    if [ "${BOOTSTRAP_OVERRIDE_SET_EDGE_SERVICE:-false}" != "true" ]; then
        EDGE_SERVICE="caddy"
    fi
    if [ "$CHUTES_TRAFFIC_MODE" = "e2ee-proxy" ]; then
        CHUTES_PROXY_BASE_URL="https://${DROPZONE_HOST}"
        CHUTES_CREDENTIAL_TEST_BASE_URL="https://${DROPZONE_HOST}"
        OPENWEBUI_API_BASE_URL="https://${DROPZONE_HOST}/v1"
    else
        CHUTES_PROXY_BASE_URL=""
        CHUTES_CREDENTIAL_TEST_BASE_URL=""
        if [ "${BOOTSTRAP_OVERRIDE_SET_OPENWEBUI_API_BASE_URL:-false}" != "true" ] && \
            { [ -z "${OPENWEBUI_API_BASE_URL:-}" ] || is_proxy_backed_openwebui_url "$OPENWEBUI_API_BASE_URL"; }; then
            OPENWEBUI_API_BASE_URL="https://llm.chutes.ai/v1"
        fi
    fi
fi

if [ "$DOWN" = true ]; then
    require_cmd docker
    if ! docker compose version >/dev/null 2>&1; then
        err "docker compose is required"
        exit 1
    fi
    compose down
    exit 0
fi

info "Pre-flight checks..."

require_cmd docker
require_cmd openssl
require_cmd rsync

if ! docker compose version >/dev/null 2>&1; then
    err "docker compose is required"
    exit 1
fi

if ! docker info >/dev/null 2>&1; then
    err "Docker daemon is not running"
    exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
    err "python3 is required"
    exit 1
fi

ok "Docker is ready"

if [ "$EXISTING_INSTALL" = true ]; then
    if [ "$INSTALL_ACTION" = "wipe" ]; then
        warn "Wipe mode selected: volumes and encrypted n8n data will be recreated from scratch"
    else
        info "Update mode selected: rebuilding cleanly while preserving existing n8n and postgres data"
    fi
fi

ensure_real_chutes_oauth_credentials

if [ -z "${POSTGRES_PASSWORD:-}" ] || [ "$FORCE_ALL" = true ]; then
    POSTGRES_PASSWORD="$(generate_hex 16)"
fi
if [ -z "${POSTGRES_N8N_USER:-}" ] || [ "$FORCE_ALL" = true ]; then
    POSTGRES_N8N_USER="dropzone_n8n"
fi
if [ -z "${POSTGRES_N8N_PASSWORD:-}" ] || [ "$FORCE_ALL" = true ]; then
    POSTGRES_N8N_PASSWORD="$(generate_hex 16)"
fi
if [ -z "${POSTGRES_OPENWEBUI_USER:-}" ] || [ "$FORCE_ALL" = true ]; then
    POSTGRES_OPENWEBUI_USER="dropzone_owui"
fi
if [ -z "${POSTGRES_OPENWEBUI_PASSWORD:-}" ] || [ "$FORCE_ALL" = true ]; then
    POSTGRES_OPENWEBUI_PASSWORD="$(generate_hex 16)"
fi
if [ -z "${N8N_ENCRYPTION_KEY:-}" ] || [ "$FORCE_ALL" = true ]; then
    N8N_ENCRYPTION_KEY="$(generate_hex 32)"
fi
if [ -z "${N8N_JWT_SECRET:-}" ] || [ "$FORCE_ALL" = true ]; then
    N8N_JWT_SECRET="$(generate_hex 32)"
fi
if [ -z "${WEBUI_SECRET_KEY:-}" ] || [ "$FORCE_ALL" = true ]; then
    WEBUI_SECRET_KEY="$(generate_hex 32)"
fi
if [ -z "${N8N_ADMIN_PASSWORD:-}" ] || [ "$FORCE_ALL" = true ] || [ "$RESET_OWNER_PASSWORD" = true ]; then
    N8N_ADMIN_PASSWORD="$(generate_owner_password)"
fi
if [ -z "${OPENWEBUI_ADMIN_PASSWORD:-}" ] || [ "$FORCE_ALL" = true ]; then
    OPENWEBUI_ADMIN_PASSWORD="$(generate_owner_password)"
fi

for required_var in \
    DROPZONE_HOST \
    CHUTES_OAUTH_CLIENT_ID \
    CHUTES_OAUTH_CLIENT_SECRET \
    CHUTES_TRAFFIC_MODE \
    N8N_ENCRYPTION_KEY \
    POSTGRES_PASSWORD \
    WEBUI_SECRET_KEY \
    OPENWEBUI_ADMIN_EMAIL \
    OPENWEBUI_ADMIN_PASSWORD
do
    if [ -z "${!required_var:-}" ]; then
        err "$required_var must not be empty"
        exit 1
    fi
done

if [ "$INSTALL_MODE" = "domain" ] && [ -z "$ACME_EMAIL" ]; then
    err "ACME_EMAIL must not be empty for domain installs"
    exit 1
fi

info "Writing .env ..."
write_env_file
ok ".env updated"

info "Rendering landing page ..."
render_landing_page
ok "Landing page rendered"

if [ "$INSTALL_MODE" = "domain" ]; then
    info "Rendering Caddy config ..."
    render_caddyfile
    ok "Caddyfile rendered"
else
    info "Rendering local proxy config ..."
    render_local_proxy_config
    ok "local-proxy nginx config rendered"
fi

NODES_SRC="$SCRIPT_DIR/../n8n-nodes-chutes"
BUILD_DIR="$SCRIPT_DIR/build/n8n-nodes-chutes"

ensure_dependency_checkout \
    "$NODES_SRC" \
    "${CHUTES_N8N_NODES_GIT_URL:-$PROJECT_NODES_REPO}" \
    "${CHUTES_N8N_NODES_GIT_REF:-$PROJECT_NODES_REF}"

refresh_local_dependency_checkout "$NODES_SRC"

info "Syncing n8n-nodes-chutes into Docker build context ..."
mkdir -p "$BUILD_DIR"
rsync -a --delete \
    --exclude node_modules \
    --exclude .git \
    --exclude tests \
    --exclude coverage \
    "$NODES_SRC/" "$BUILD_DIR/"
node "$SCRIPT_DIR/scripts/patch-n8n-nodes-chutes.mjs" "$BUILD_DIR"
ok "Custom node build context is ready"

if [ "$FORCE_ALL" = true ]; then
    info "Removing existing docker volumes for a clean redeploy ..."
    compose down -v --remove-orphans || true
    remove_stale_project_containers
elif [ "$EXISTING_INSTALL" = true ] && [ "$INSTALL_ACTION" = "update" ]; then
    info "Stopping the existing stack for a clean in-place rebuild ..."
    compose down --remove-orphans || true
    remove_stale_project_containers
fi

if [ "$SKIP_BUILD" = true ]; then
    warn "SKIP_BUILD=true; assuming all referenced images already exist locally"
elif [ "$SKIP_APP_BUILDS" = true ]; then
    info "Building edge/helper images only ..."
    build_services=()
    case "$INSTALL_MODE" in
        local) build_services+=(local-proxy) ;;
        domain) ;;
    esac
    if [ "$CHUTES_TRAFFIC_MODE" = "e2ee-proxy" ]; then
        build_services+=(e2ee-proxy)
    fi
    if [ "${#build_services[@]}" -gt 0 ]; then
        compose build "${build_services[@]}"
    else
        info "No edge/helper images need building for this stack shape"
    fi
else
    info "Building images ..."
    compose build
fi

remove_stale_edge_container

info "Starting services ..."
if [ "$SKIP_BUILD" = true ] || [ "$SKIP_APP_BUILDS" = true ]; then
    compose up -d --no-build
else
    compose up -d
fi

info "Waiting for n8n to become healthy ..."
attempts=0
max_attempts=80
status="starting"
while [ "$attempts" -lt "$max_attempts" ]; do
    status="$(container_runtime_status "$(compose_container_id n8n)")"
    if [ "$status" = "healthy" ]; then
        break
    fi
    attempts=$((attempts + 1))
    if [ $((attempts % 5)) -eq 0 ]; then
        echo "    still waiting... ($status)"
    fi
    sleep 3
done

if [ "$status" != "healthy" ]; then
    err "n8n did not become healthy"
    err "Check logs with: $(compose_command_hint) logs n8n ${EDGE_SERVICE}"
    exit 1
fi
ok "n8n is healthy"

info "Waiting for OpenWebUI to become healthy ..."
attempts=0
max_attempts=80
status="starting"
while [ "$attempts" -lt "$max_attempts" ]; do
    status="$(container_runtime_status "$(compose_container_id openwebui)")"
    if [ "$status" = "healthy" ]; then
        break
    fi
    attempts=$((attempts + 1))
    if [ $((attempts % 5)) -eq 0 ]; then
        echo "    still waiting... ($status)"
    fi
    sleep 3
done

if [ "$status" != "healthy" ]; then
    err "OpenWebUI did not become healthy"
    err "Check logs with: $(compose_command_hint) logs openwebui ${EDGE_SERVICE}"
    exit 1
fi
ok "OpenWebUI is healthy"

info "Waiting for ${EDGE_SERVICE} to become ready ..."
edge_status="$(wait_for_service_ready "$EDGE_SERVICE" 30 || true)"
if [ "$edge_status" != "healthy" ] && [ "$edge_status" != "running" ]; then
    err "${EDGE_SERVICE} did not become ready (status: ${edge_status})"
    err "Check logs with: $(compose_command_hint) logs ${EDGE_SERVICE}"
    exit 1
fi
ok "${EDGE_SERVICE} is ${edge_status}"

info "Configuring n8n ..."
RESET_OWNER_PASSWORD="$RESET_OWNER_PASSWORD" "$SCRIPT_DIR/scripts/configure-n8n.sh"

info "Verifying OpenWebUI ..."
"$SCRIPT_DIR/scripts/configure-openwebui.sh"

OWNER_PASSWORD_VALID=false
if check_owner_login; then
    OWNER_PASSWORD_VALID=true
fi

echo
echo -e "${GREEN}${BOLD}========================================${NC}"
echo -e "${GREEN}${BOLD}  Chutes Dropzone is ready${NC}"
echo -e "${GREEN}${BOLD}========================================${NC}"
echo
echo -e "  Mode: ${BOLD}${INSTALL_MODE}${NC}"
if [ "${DROPZONE_ENABLE_PUBLIC_LANDING:-true}" = "true" ]; then
    echo -e "  Landing: ${BOLD}https://${DROPZONE_HOST}/${NC}"
else
    echo -e "  Root:    ${BOLD}https://${DROPZONE_HOST}/${NC} ${CYAN}(redirects to /chat/)${NC}"
fi
echo -e "  Chat:    ${BOLD}https://${DROPZONE_HOST}/chat/${NC}"
echo -e "  n8n:     ${BOLD}https://${DROPZONE_HOST}/n8n/${NC}"
echo
echo "  Chutes OAuth app settings:"
echo "    Redirect URI: https://${DROPZONE_HOST}/oauth/oidc/callback"
echo "                  https://${DROPZONE_HOST}/rest/sso/chutes/callback"
if [ "$INSTALL_MODE" = "local" ]; then
    echo "    TLS: embedded e2ee-proxy certificate for ${LOCAL_HOSTNAME}"
else
    echo "    TLS: Let's Encrypt via Caddy"
fi
echo
echo "  Chutes SSO is enabled on OpenWebUI and the native n8n sign-in page."
echo "  Chutes traffic mode:"
if [ "$CHUTES_TRAFFIC_MODE" = "e2ee-proxy" ]; then
    echo "    e2ee-proxy - OpenAI-compatible LLM text traffic is routed through the existing e2ee-proxy path"
    if [ "$ALLOW_NON_CONFIDENTIAL" = "true" ]; then
        echo "    non-TEE text models are allowed through the proxy path"
    else
        echo "    TEE-only by default; set ALLOW_NON_CONFIDENTIAL=true to allow non-TEE text models"
    fi
    echo "    SSO and API-key text execution both use the proxy path"
else
    echo "    direct - native Chutes endpoints are used so Chutes routing/failover behavior stays intact"
    if [ "$INSTALL_MODE" = "local" ]; then
        echo "    local e2ee-proxy is still used for the embedded local certificate and serving n8n"
    fi
fi
echo
if [ "$OWNER_PASSWORD_VALID" = true ]; then
    echo "  Break-glass admins:"
    echo "    Email:    ${N8N_ADMIN_EMAIL}"
    if [ "$INTERACTIVE" = true ]; then
        echo -e "    Password: ${BOLD}${N8N_ADMIN_PASSWORD}${NC}"
    else
        echo "    Password: (stored in .env — run interactively to display)"
    fi
    echo "    OpenWebUI email:    ${OPENWEBUI_ADMIN_EMAIL}"
    if [ "$INTERACTIVE" = true ]; then
        echo -e "    OpenWebUI password: ${BOLD}${OPENWEBUI_ADMIN_PASSWORD}${NC}"
    else
        echo "    OpenWebUI password: (stored in .env — run interactively to display)"
    fi
else
    warn "Stored owner credentials could not be verified."
    warn "Run ./deploy.sh --reset-owner-password to rotate the break-glass owner password."
fi
echo
echo "  Commands:"
echo "    Logs:    $(compose_command_hint) logs -f"
echo "    Stop:    $(compose_command_hint) down"
echo "    Re-test: $SCRIPT_DIR/scripts/smoke-test.sh --syntax"
echo
