#!/usr/bin/env bash
#
# release.sh
#
# Interactive helper for cutting a new GitHub release. It:
# - proposes the next patch version from existing tags
# - confirms the chosen version
# - prints pinned refs and image digests used by CI/release builds
# - reminds the operator about security-relevant pins before publishing
# - publishes a GitHub release via `gh`, which triggers the release workflow
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

DOCKERFILE_PATH="$SCRIPT_DIR/Dockerfile.local-repo"
CI_WORKFLOW_PATH="$SCRIPT_DIR/.github/workflows/ci.yml"
RELEASE_WORKFLOW_PATH="$SCRIPT_DIR/.github/workflows/release.yml"
DEPLOY_SCRIPT_PATH="$SCRIPT_DIR/deploy.sh"

VERSION_OVERRIDE=""
DRY_RUN=false
YES=false

usage() {
    cat <<'EOF'
Usage: ./release.sh [--version vX.Y.Z] [--dry-run] [--yes]

Options:
  --version   Use an explicit version instead of the proposed next patch tag
  --dry-run   Print the release plan and pinned refs, then exit
  --yes       Skip the final publish confirmation prompt
  -h, --help  Show this help
EOF
}

log() {
    printf '[release] %s\n' "$1"
}

warn() {
    printf '[release] warning: %s\n' "$1" >&2
}

err() {
    printf '[release] error: %s\n' "$1" >&2
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        err "$1 is required"
        exit 1
    }
}

have_cmd() {
    command -v "$1" >/dev/null 2>&1
}

extract_arg() {
    local name="$1"
    sed -n "s/^ARG ${name}=//p" "$DOCKERFILE_PATH" | head -n 1
}

extract_yaml_value() {
    local file="$1"
    local key="$2"
    sed -n "s/^[[:space:]]*${key}:[[:space:]]*//p" "$file" | head -n 1
}

extract_shell_value() {
    local file="$1"
    local key="$2"
    sed -n "s/^${key}=\"\\(.*\\)\"$/\\1/p" "$file" | head -n 1
}

current_branch() {
    git rev-parse --abbrev-ref HEAD
}

current_head() {
    git rev-parse --short=12 HEAD
}

ensure_clean_worktree() {
    local status
    status="$(git status --porcelain)"
    if [ -n "$status" ]; then
        err "working tree is not clean; commit or stash changes before cutting a release"
        exit 1
    fi
}

fetch_tags() {
    git fetch --quiet --tags origin >/dev/null 2>&1 || true
}

latest_version_tag() {
    git tag --sort=-version:refname | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -n 1
}

suggest_next_version() {
    local latest="${1:-}"
    local major minor patch

    if [ -z "$latest" ]; then
        printf 'v0.1.0'
        return
    fi

    latest="${latest#v}"
    IFS='.' read -r major minor patch <<< "$latest"
    printf 'v%s.%s.%s' "$major" "$minor" "$((patch + 1))"
}

normalize_version() {
    local version="$1"
    if [[ "$version" != v* ]]; then
        version="v${version}"
    fi
    printf '%s' "$version"
}

validate_version() {
    [[ "$1" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

prompt_with_default() {
    local prompt="$1"
    local default_value="$2"
    local answer=""

    if [ ! -t 0 ] || [ ! -t 1 ]; then
        printf '%s' "$default_value"
        return
    fi

    read -r -p "$prompt [$default_value]: " answer
    if [ -z "$answer" ]; then
        printf '%s' "$default_value"
    else
        printf '%s' "$answer"
    fi
}

report_gh_requirement() {
    local os_name arch

    os_name="$(uname -s)"
    arch="$(uname -m)"

    err "gh is required to publish a release"
    warn "GitHub CLI does not provide an official curl installer of its own"
    printf '[release] platform: %s/%s\n' "$os_name" "$arch" >&2
    printf '[release] install docs: https://cli.github.com/manual/installation\n' >&2

    case "$os_name" in
        Darwin)
            printf '[release] install hint: brew install gh\n' >&2
            ;;
        Linux)
            if have_cmd brew; then
                printf '[release] install hint: brew install gh\n' >&2
            elif have_cmd apt-get && [ -f /etc/debian_version ]; then
                printf '[release] install hint: use the official Debian/Ubuntu instructions, then install gh\n' >&2
            elif have_cmd dnf; then
                printf '[release] install hint: use the official RPM instructions, then run sudo dnf install gh\n' >&2
            elif have_cmd yum; then
                printf '[release] install hint: use the official RPM instructions, then run sudo yum install gh\n' >&2
            elif have_cmd zypper; then
                printf '[release] install hint: use the official RPM instructions, then run sudo zypper install gh\n' >&2
            else
                printf '[release] install hint: follow the official install docs for this Linux distribution\n' >&2
            fi
            ;;
        *)
            printf '[release] install hint: follow the official install docs for this platform\n' >&2
            ;;
    esac
}

ensure_gh_available() {
    if have_cmd gh; then
        return 0
    fi

    report_gh_requirement
    exit 1
}

review_pin_value() {
    local label="$1"
    local current_value="$2"
    local source_hint="$3"
    local answer=""

    if [ ! -t 0 ] || [ ! -t 1 ]; then
        return 0
    fi

    printf '\n[release] %s\n' "$label"
    printf '[release]   source: %s\n' "$source_hint"
    read -r -p "[release]   confirm [$current_value]: " answer
    answer="${answer:-$current_value}"

    if [ "$answer" != "$current_value" ]; then
        err "$label differs from the checked-in pin"
        err "update the repo to '$answer', commit it, and rerun release.sh"
        exit 1
    fi
}

confirm() {
    local prompt="$1"
    local answer=""

    if [ "$YES" = true ]; then
        return 0
    fi

    if [ ! -t 0 ] || [ ! -t 1 ]; then
        return 1
    fi

    read -r -p "$prompt [y/N]: " answer
    case "${answer:-N}" in
        y|Y|yes|YES) return 0 ;;
        *) return 1 ;;
    esac
}

tag_exists() {
    local version="$1"
    git rev-parse -q --verify "refs/tags/$version" >/dev/null 2>&1 && return 0
    git ls-remote --exit-code --tags origin "refs/tags/$version" >/dev/null 2>&1 && return 0
    return 1
}

print_release_plan() {
    local latest_tag="$1"
    local proposed_tag="$2"
    local chosen_tag="$3"
    local ci_nodes_ref="$4"
    local release_nodes_ref="$5"
    local n8n_source_ref="$6"
    local n8n_source_sha="$7"
    local proxy_image="$8"
    local node_image="$9"
    local n8n_base_image="${10}"
    local openwebui_version="${11}"
    local caddy_image="${12}"

    cat <<EOF
Release plan
  branch: $(current_branch)
  head:   $(current_head)
  latest: ${latest_tag:-<none>}
  next:   $proposed_tag
  chosen: $chosen_tag

Pinned refs and images
  n8n-nodes-chutes (ci):      $ci_nodes_ref
  n8n-nodes-chutes (release): $release_nodes_ref
  n8n source ref:             $n8n_source_ref
  n8n source sha:             $n8n_source_sha
  e2ee-proxy image:           $proxy_image
  node builder image:         $node_image
  n8nio/base image:           $n8n_base_image
  OpenWebUI version:          $openwebui_version
  caddy image:                $caddy_image

Publish target
  workflow: .github/workflows/release.yml
  dockerfile: Dockerfile.local-repo
  platform: linux/amd64
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --version=*)
            VERSION_OVERRIDE="${1#*=}"
            ;;
        --version)
            shift || true
            if [ "$#" -eq 0 ]; then
                err "--version requires a value"
                exit 1
            fi
            VERSION_OVERRIDE="${1:-}"
            ;;
        --dry-run)
            DRY_RUN=true
            ;;
        --yes)
            YES=true
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            err "unknown argument: $1"
            usage
            exit 1
            ;;
    esac
    shift
done

require_cmd git

if [ "$DRY_RUN" != true ]; then
    ensure_clean_worktree
fi
fetch_tags

latest_tag="$(latest_version_tag)"
proposed_tag="$(suggest_next_version "$latest_tag")"

if [ -n "$VERSION_OVERRIDE" ]; then
    chosen_tag="$(normalize_version "$VERSION_OVERRIDE")"
else
    chosen_tag="$(normalize_version "$(prompt_with_default "Release version" "$proposed_tag")")"
fi

if ! validate_version "$chosen_tag"; then
    err "version must look like vX.Y.Z"
    exit 1
fi

if tag_exists "$chosen_tag"; then
    err "tag already exists: $chosen_tag"
    exit 1
fi

ci_nodes_ref="$(extract_yaml_value "$CI_WORKFLOW_PATH" "N8N_NODES_CHUTES_REF")"
release_nodes_ref="$(extract_yaml_value "$RELEASE_WORKFLOW_PATH" "N8N_NODES_CHUTES_REF")"
n8n_source_ref="$(extract_arg "N8N_SOURCE_REF")"
n8n_source_sha="$(extract_arg "N8N_SOURCE_SHA")"
proxy_image="$(extract_arg "E2EE_PROXY_IMAGE")"
node_image="$(extract_arg "NODE_BUILDER_IMAGE")"
n8n_base_image="$(extract_arg "N8N_BASE_IMAGE")"
openwebui_version="$(extract_arg "OPENWEBUI_VERSION")"
caddy_image="$(extract_arg "CADDY_IMAGE")"
deploy_nodes_ref="$(extract_shell_value "$DEPLOY_SCRIPT_PATH" "PROJECT_NODES_REF")"

if [ -z "$ci_nodes_ref" ] || [ -z "$release_nodes_ref" ]; then
    err "could not determine pinned n8n-nodes-chutes ref from workflows"
    exit 1
fi

if [ "$ci_nodes_ref" != "$release_nodes_ref" ]; then
    err "ci and release workflows disagree on N8N_NODES_CHUTES_REF"
    exit 1
fi

review_pin_value \
    "n8n-nodes-chutes ref" \
    "$ci_nodes_ref" \
    ".github/workflows/ci.yml + .github/workflows/release.yml"
review_pin_value \
    "n8n source ref" \
    "$n8n_source_ref" \
    "Dockerfile.local-repo ARG N8N_SOURCE_REF"
review_pin_value \
    "n8n source sha" \
    "$n8n_source_sha" \
    "Dockerfile.local-repo ARG N8N_SOURCE_SHA"
review_pin_value \
    "e2ee-proxy image" \
    "$proxy_image" \
    "Dockerfile.local-repo ARG E2EE_PROXY_IMAGE"
review_pin_value \
    "node builder image" \
    "$node_image" \
    "Dockerfile.local-repo ARG NODE_BUILDER_IMAGE"
review_pin_value \
    "n8nio/base image" \
    "$n8n_base_image" \
    "Dockerfile.local-repo ARG N8N_BASE_IMAGE"
review_pin_value \
    "caddy image" \
    "$caddy_image" \
    "Dockerfile.local-repo ARG CADDY_IMAGE"
review_pin_value \
    "OpenWebUI version" \
    "$openwebui_version" \
    "Dockerfile.local-repo ARG OPENWEBUI_VERSION"

print_release_plan \
    "$latest_tag" \
    "$proposed_tag" \
    "$chosen_tag" \
    "$ci_nodes_ref" \
    "$release_nodes_ref" \
    "$n8n_source_ref" \
    "$n8n_source_sha" \
    "$proxy_image" \
    "$node_image" \
    "$n8n_base_image" \
    "$openwebui_version" \
    "$caddy_image"

cat <<EOF

Reminder
  - The n8n-nodes-chutes commit above is pinned in CI/release for supply-chain safety.
  - If you bump upstream versions, update the matching pins before publishing.
  - repo-based deploys currently default n8n-nodes-chutes to: ${deploy_nodes_ref:-<unknown>}
  - Shipping happens when this script publishes a GitHub release.
EOF

if [ "$DRY_RUN" = true ]; then
    exit 0
fi

ensure_gh_available

if ! confirm "Publish GitHub release $chosen_tag from $(current_head)?"; then
    log "release cancelled"
    exit 0
fi

gh release create "$chosen_tag" \
    --target "$(git rev-parse HEAD)" \
    --title "$chosen_tag" \
    --generate-notes

log "published GitHub release $chosen_tag"
log "the release workflow should now build and push the linux/amd64 package"
