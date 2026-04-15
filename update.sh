#!/usr/bin/env bash
#
# update.sh
#
# Interactive helper for refreshing checked-in upstream pins, validating the
# result locally, then pushing a test PR so CI can shake out overlay breakage
# before anything lands on main.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

DOCKERFILE_LOCAL_REPO="$SCRIPT_DIR/Dockerfile.local-repo"
DOCKERFILE_N8N="$SCRIPT_DIR/Dockerfile.n8n"
DEPLOY_SCRIPT_PATH="$SCRIPT_DIR/deploy.sh"
COMPOSE_FILE_PATH="$SCRIPT_DIR/docker-compose.yml"
ENV_EXAMPLE_PATH="$SCRIPT_DIR/.env.example"
SMOKE_TEST_PATH="$SCRIPT_DIR/scripts/smoke-test.sh"
RELEASE_HELPER_PATH="$SCRIPT_DIR/release.sh"
DEFAULT_REMOTE="${GIT_REMOTE:-}"

PLATFORM_OS="linux"
PLATFORM_ARCH="amd64"

DRY_RUN=false
YES=false
ALL_COMPONENTS=false
PUSH_CHANGES=true
OPEN_PR=true
BASE_BRANCH_OVERRIDE=""

REQUESTED_COMPONENTS=()
SELECTED_COMPONENTS=()

N8N_HAS_UPDATE=false
N8N_CURRENT_REF=""
N8N_CURRENT_SHA=""
N8N_CURRENT_NODE_VERSION=""
N8N_CURRENT_NODE_IMAGE=""
N8N_CURRENT_BASE_IMAGE=""
N8N_LATEST_VERSION=""
N8N_LATEST_REF=""
N8N_LATEST_SHA=""
N8N_LATEST_NODE_VERSION=""
N8N_LATEST_NODE_IMAGE=""
N8N_LATEST_BASE_IMAGE=""

OPENWEBUI_HAS_UPDATE=false
OPENWEBUI_CURRENT_VERSION=""
OPENWEBUI_CURRENT_IMAGE=""
OPENWEBUI_LATEST_VERSION=""
OPENWEBUI_LATEST_IMAGE=""

usage() {
    cat <<'EOF'
Usage: ./update.sh [component ...] [options]

Components:
  n8n         Refresh the pinned n8n source ref/sha and its builder/runtime images
  openwebui   Refresh the pinned OpenWebUI release tag and image digest

Options:
  --all       Consider every supported component
  --base BR   Base branch for the PR (defaults to the repo default branch, usually main)
  --dry-run   Print available updates and the branch/PR plan without changing files
  --yes       Accept the proposed updates and publish flow without prompting
  --no-push   Commit the branch locally but do not push or open a PR
  --no-pr     Push the branch but stop before opening a PR
  -h, --help  Show this help
EOF
}

log() {
    printf '[update] %s\n' "$1"
}

warn() {
    printf '[update] warning: %s\n' "$1" >&2
}

err() {
    printf '[update] error: %s\n' "$1" >&2
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

current_branch() {
    git rev-parse --abbrev-ref HEAD
}

current_head() {
    git rev-parse --short=12 HEAD
}

preferred_remote() {
    local upstream_remote=""
    local first_remote=""

    if [ -n "$DEFAULT_REMOTE" ]; then
        printf '%s' "$DEFAULT_REMOTE"
        return
    fi

    upstream_remote="$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null | sed 's#/.*##' || true)"
    if [ -n "$upstream_remote" ]; then
        printf '%s' "$upstream_remote"
        return
    fi

    if git remote | grep -qx origin; then
        printf 'origin'
        return
    fi

    first_remote="$(git remote | head -n 1 || true)"
    printf '%s' "$first_remote"
}

ensure_clean_worktree() {
    local status
    status="$(git status --porcelain)"
    if [ -n "$status" ]; then
        err "working tree is not clean; commit or stash changes before running update.sh"
        exit 1
    fi
}

ensure_gh_ready() {
    if ! have_cmd gh; then
        err "gh is required"
        err "install docs: https://cli.github.com/manual/installation"
        exit 1
    fi

    if ! gh auth status >/dev/null 2>&1; then
        err "gh is not authenticated; run 'gh auth login' first"
        exit 1
    fi
}

ensure_docker_ready() {
    require_cmd docker
    if ! docker buildx version >/dev/null 2>&1; then
        err "docker buildx is required"
        exit 1
    fi
}

extract_arg() {
    local file="$1"
    local name="$2"
    sed -n "s/^ARG ${name}=//p" "$file" | head -n 1
}

set_shell_assignment() {
    local file="$1"
    local key="$2"
    local value="$3"

    python3 - "$file" "$key" "$value" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
key = sys.argv[2]
value = sys.argv[3]
pattern = re.compile(rf"^{re.escape(key)}=\".*\"$", re.MULTILINE)
replacement = f'{key}="{value}"'
text = path.read_text()
updated, count = pattern.subn(replacement, text, count=1)
if count != 1:
    raise SystemExit(f"{path}: expected exactly one assignment for {key}, found {count}")
path.write_text(updated)
PY
}

set_docker_arg() {
    local file="$1"
    local key="$2"
    local value="$3"

    python3 - "$file" "$key" "$value" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
key = sys.argv[2]
value = sys.argv[3]
pattern = re.compile(rf"^ARG {re.escape(key)}=.*$", re.MULTILINE)
replacement = f"ARG {key}={value}"
text = path.read_text()
updated, count = pattern.subn(replacement, text, count=1)
if count != 1:
    raise SystemExit(f"{path}: expected exactly one ARG for {key}, found {count}")
path.write_text(updated)
PY
}

set_compose_default() {
    local file="$1"
    local key="$2"
    local value="$3"

    python3 - "$file" "$key" "$value" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
key = sys.argv[2]
value = sys.argv[3]
pattern = re.compile(
    rf"^(?P<indent>\s*{re.escape(key)}:\s*)\$\{{{re.escape(key)}:-.*\}}$",
    re.MULTILINE,
)
text = path.read_text()

def repl(match):
    return match.group("indent") + "${" + key + ":-" + value + "}"

updated, count = pattern.subn(repl, text, count=1)
if count != 1:
    raise SystemExit(f"{path}: expected exactly one compose default for {key}, found {count}")
path.write_text(updated)
PY
}

github_file_contents() {
    local endpoint="$1"
    gh api "$endpoint" --jq .content | python3 -c '
import base64
import sys

payload = sys.stdin.read().strip().replace("\n", "")
sys.stdout.write(base64.b64decode(payload).decode())
'
}

resolve_manifest_digest() {
    local image_ref="$1"

    docker buildx imagetools inspect "$image_ref" --format '{{json .Manifest}}' | \
        python3 -c '
import json
import sys

target_os = sys.argv[1]
target_arch = sys.argv[2]
image_ref = sys.argv[3]
payload = json.load(sys.stdin)

manifests = payload.get("manifests") or []
if manifests:
    for manifest in manifests:
        platform = manifest.get("platform") or {}
        if platform.get("os") == target_os and platform.get("architecture") == target_arch:
            print(manifest["digest"])
            raise SystemExit(0)
    raise SystemExit(f"{image_ref}: no {target_os}/{target_arch} manifest found")

digest = payload.get("digest")
if digest:
    print(digest)
    raise SystemExit(0)

raise SystemExit(f"{image_ref}: could not determine manifest digest")
' "$PLATFORM_OS" "$PLATFORM_ARCH" "$image_ref"
}

latest_n8n_tag() {
    gh api -X GET 'repos/n8n-io/n8n/tags?per_page=100' --paginate --jq '.[].name' | python3 -c '
import re
import sys

pattern = re.compile(r"^n8n@(\d+)\.(\d+)\.(\d+)$")
tags = []
for raw in sys.stdin:
    tag = raw.strip()
    match = pattern.match(tag)
    if not match:
        continue
    version = tuple(int(part) for part in match.groups())
    tags.append((version, tag))

if not tags:
    raise SystemExit("no stable n8n tags found")

tags.sort()
print(tags[-1][1])
'
}

n8n_node_version_for_tag() {
    local tag="$1"
    github_file_contents "repos/n8n-io/n8n/contents/docker/images/n8n-base/Dockerfile?ref=${tag}" | \
        sed -n 's/^ARG NODE_VERSION=//p' | head -n 1
}

short_sha() {
    local value="$1"
    if [ -z "$value" ]; then
        printf '<none>'
    else
        printf '%.12s' "$value"
    fi
}

short_digest() {
    local value="${1#*@}"
    value="${value#sha256:}"
    if [ -z "$value" ]; then
        printf '<none>'
    else
        printf 'sha256:%.12s' "$value"
    fi
}

node_version_from_builder_image() {
    local image="$1"
    local value="${image#node:}"
    value="${value%%-alpine*}"
    printf '%s' "$value"
}

component_label() {
    case "$1" in
        n8n) printf 'n8n' ;;
        openwebui) printf 'OpenWebUI' ;;
        *)
            err "unsupported component: $1"
            exit 1
            ;;
    esac
}

component_abbr() {
    case "$1" in
        n8n) printf 'n8n' ;;
        openwebui) printf 'owui' ;;
        *)
            err "unsupported component: $1"
            exit 1
            ;;
    esac
}

component_has_update() {
    case "$1" in
        n8n) [ "$N8N_HAS_UPDATE" = true ] ;;
        openwebui) [ "$OPENWEBUI_HAS_UPDATE" = true ] ;;
        *)
            err "unsupported component: $1"
            exit 1
            ;;
    esac
}

component_current_summary() {
    case "$1" in
        n8n)
            printf '%s (%s), node %s' \
                "$N8N_CURRENT_REF" \
                "$(short_sha "$N8N_CURRENT_SHA")" \
                "$N8N_CURRENT_NODE_VERSION"
            ;;
        openwebui)
            printf '%s (%s)' \
                "$OPENWEBUI_CURRENT_VERSION" \
                "$(short_digest "$OPENWEBUI_CURRENT_IMAGE")"
            ;;
        *)
            err "unsupported component: $1"
            exit 1
            ;;
    esac
}

component_latest_summary() {
    case "$1" in
        n8n)
            printf '%s (%s), node %s' \
                "$N8N_LATEST_REF" \
                "$(short_sha "$N8N_LATEST_SHA")" \
                "$N8N_LATEST_NODE_VERSION"
            ;;
        openwebui)
            printf '%s (%s)' \
                "$OPENWEBUI_LATEST_VERSION" \
                "$(short_digest "$OPENWEBUI_LATEST_IMAGE")"
            ;;
        *)
            err "unsupported component: $1"
            exit 1
            ;;
    esac
}

component_pr_summary() {
    case "$1" in
        n8n)
            cat <<EOF
- update n8n source from \`$N8N_CURRENT_REF\` (\`$(short_sha "$N8N_CURRENT_SHA")\`) to \`$N8N_LATEST_REF\` (\`$(short_sha "$N8N_LATEST_SHA")\`)
- update the n8n node builder image from \`$N8N_CURRENT_NODE_IMAGE\` to \`$N8N_LATEST_NODE_IMAGE\`
- update the n8n base image from \`$N8N_CURRENT_BASE_IMAGE\` to \`$N8N_LATEST_BASE_IMAGE\`
EOF
            ;;
        openwebui)
            cat <<EOF
- update OpenWebUI from \`$OPENWEBUI_CURRENT_VERSION\` (\`$(short_digest "$OPENWEBUI_CURRENT_IMAGE")\`) to \`$OPENWEBUI_LATEST_VERSION\` (\`$(short_digest "$OPENWEBUI_LATEST_IMAGE")\`)
EOF
            ;;
        *)
            err "unsupported component: $1"
            exit 1
            ;;
    esac
}

append_unique_component() {
    local component="$1"
    local existing
    for existing in "${SELECTED_COMPONENTS[@]:-}"; do
        [ "$existing" = "$component" ] && return 0
    done
    SELECTED_COMPONENTS+=("$component")
}

join_by() {
    local delimiter="$1"
    shift
    local first=true
    local item
    for item in "$@"; do
        if [ "$first" = true ]; then
            printf '%s' "$item"
            first=false
        else
            printf '%s%s' "$delimiter" "$item"
        fi
    done
}

human_component_list() {
    local labels=()
    local component
    local count

    for component in "$@"; do
        labels+=("$(component_label "$component")")
    done

    count="${#labels[@]}"
    if [ "$count" -eq 0 ]; then
        printf 'updates'
        return
    fi

    if [ "$count" -eq 1 ]; then
        printf '%s' "${labels[0]}"
        return
    fi

    if [ "$count" -eq 2 ]; then
        printf '%s and %s' "${labels[0]}" "${labels[1]}"
        return
    fi

    local index=0
    while [ "$index" -lt "$count" ]; do
        if [ "$index" -gt 0 ]; then
            if [ "$index" -eq $((count - 1)) ]; then
                printf ', and '
            else
                printf ', '
            fi
        fi
        printf '%s' "${labels[$index]}"
        index=$((index + 1))
    done
}

prompt_yes_no_default() {
    local prompt="$1"
    local default_answer="$2"
    local answer=""

    if [ "$YES" = true ]; then
        [ "$default_answer" = "yes" ]
        return
    fi

    if [ ! -t 0 ] || [ ! -t 1 ]; then
        [ "$default_answer" = "yes" ]
        return
    fi

    if [ "$default_answer" = "yes" ]; then
        read -r -p "$prompt [Y/n]: " answer
        case "${answer:-Y}" in
            y|Y|yes|YES) return 0 ;;
            *) return 1 ;;
        esac
    else
        read -r -p "$prompt [y/N]: " answer
        case "${answer:-N}" in
            y|Y|yes|YES) return 0 ;;
            *) return 1 ;;
        esac
    fi
}

discover_n8n_update() {
    N8N_CURRENT_REF="$(extract_arg "$DOCKERFILE_LOCAL_REPO" "N8N_SOURCE_REF")"
    N8N_CURRENT_SHA="$(extract_arg "$DOCKERFILE_LOCAL_REPO" "N8N_SOURCE_SHA")"
    N8N_CURRENT_NODE_IMAGE="$(extract_arg "$DOCKERFILE_LOCAL_REPO" "NODE_BUILDER_IMAGE")"
    N8N_CURRENT_BASE_IMAGE="$(extract_arg "$DOCKERFILE_LOCAL_REPO" "N8N_BASE_IMAGE")"
    N8N_CURRENT_NODE_VERSION="$(node_version_from_builder_image "$N8N_CURRENT_NODE_IMAGE")"

    N8N_LATEST_REF="$(latest_n8n_tag)"
    N8N_LATEST_VERSION="${N8N_LATEST_REF#n8n@}"
    N8N_LATEST_SHA="$(git ls-remote --tags https://github.com/n8n-io/n8n.git "refs/tags/${N8N_LATEST_REF}" | awk '{print $1}')"
    if [ -z "$N8N_LATEST_SHA" ]; then
        err "could not resolve ${N8N_LATEST_REF} to a git commit"
        exit 1
    fi
    N8N_LATEST_NODE_VERSION="$(n8n_node_version_for_tag "$N8N_LATEST_REF")"
    if [ -z "$N8N_LATEST_NODE_VERSION" ]; then
        err "could not determine the node version for ${N8N_LATEST_REF}"
        exit 1
    fi
    N8N_LATEST_NODE_IMAGE="node:${N8N_LATEST_NODE_VERSION}-alpine@$(resolve_manifest_digest "node:${N8N_LATEST_NODE_VERSION}-alpine")"
    N8N_LATEST_BASE_IMAGE="n8nio/base:${N8N_LATEST_NODE_VERSION}@$(resolve_manifest_digest "n8nio/base:${N8N_LATEST_NODE_VERSION}")"

    if [ "$N8N_CURRENT_REF" != "$N8N_LATEST_REF" ] || \
       [ "$N8N_CURRENT_SHA" != "$N8N_LATEST_SHA" ] || \
       [ "$N8N_CURRENT_NODE_IMAGE" != "$N8N_LATEST_NODE_IMAGE" ] || \
       [ "$N8N_CURRENT_BASE_IMAGE" != "$N8N_LATEST_BASE_IMAGE" ]; then
        N8N_HAS_UPDATE=true
    else
        N8N_HAS_UPDATE=false
    fi
}

discover_openwebui_update() {
    OPENWEBUI_CURRENT_VERSION="$(extract_arg "$DOCKERFILE_LOCAL_REPO" "OPENWEBUI_VERSION")"
    OPENWEBUI_CURRENT_IMAGE="$(extract_arg "$DOCKERFILE_LOCAL_REPO" "OPENWEBUI_IMAGE")"
    OPENWEBUI_LATEST_VERSION="$(gh api 'repos/open-webui/open-webui/releases/latest' --jq .tag_name)"
    OPENWEBUI_LATEST_IMAGE="ghcr.io/open-webui/open-webui:${OPENWEBUI_LATEST_VERSION}@$(resolve_manifest_digest "ghcr.io/open-webui/open-webui:${OPENWEBUI_LATEST_VERSION}")"

    if [ "$OPENWEBUI_CURRENT_VERSION" != "$OPENWEBUI_LATEST_VERSION" ] || \
       [ "$OPENWEBUI_CURRENT_IMAGE" != "$OPENWEBUI_LATEST_IMAGE" ]; then
        OPENWEBUI_HAS_UPDATE=true
    else
        OPENWEBUI_HAS_UPDATE=false
    fi
}

print_component_report() {
    local component="$1"
    local status="up to date"

    if component_has_update "$component"; then
        status="update available"
    fi

    printf '  %s: %s\n' "$(component_label "$component")" "$status"
    printf '    current: %s\n' "$(component_current_summary "$component")"
    printf '    latest:  %s\n' "$(component_latest_summary "$component")"
}

validate_component_name() {
    case "$1" in
        n8n|openwebui) ;;
        *)
            err "unsupported component: $1"
            usage
            exit 1
            ;;
    esac
}

build_selection() {
    local component

    if [ "$ALL_COMPONENTS" = true ]; then
        REQUESTED_COMPONENTS=(n8n openwebui)
    fi

    if [ "${#REQUESTED_COMPONENTS[@]}" -gt 0 ]; then
        for component in "${REQUESTED_COMPONENTS[@]}"; do
            if component_has_update "$component"; then
                append_unique_component "$component"
            else
                warn "$(component_label "$component") is already up to date"
            fi
        done
        return
    fi

    if [ "$YES" = true ]; then
        for component in n8n openwebui; do
            if component_has_update "$component"; then
                append_unique_component "$component"
            fi
        done
        return
    fi

    if [ "$DRY_RUN" = true ]; then
        return
    fi

    if [ ! -t 0 ] || [ ! -t 1 ]; then
        err "no TTY available; pass explicit components or use --all with --yes"
        exit 1
    fi

    for component in n8n openwebui; do
        if ! component_has_update "$component"; then
            continue
        fi

        if prompt_yes_no_default "Apply $(component_label "$component") update?" "yes"; then
            append_unique_component "$component"
        fi
    done
}

default_branch() {
    if [ -n "$BASE_BRANCH_OVERRIDE" ]; then
        printf '%s' "$BASE_BRANCH_OVERRIDE"
        return
    fi

    gh repo view --json defaultBranchRef --jq .defaultBranchRef.name
}

branch_name_for_selection() {
    local date_stamp
    local tokens=()
    local component
    local branch
    local candidate
    local suffix=1
    local git_remote="$1"

    for component in "${SELECTED_COMPONENTS[@]}"; do
        tokens+=("$(component_abbr "$component")")
    done

    date_stamp="$(date +%Y-%m-%d)"
    branch="test-update-$(join_by '-' "${tokens[@]}")-${date_stamp}"
    candidate="$branch"

    while git show-ref --verify --quiet "refs/heads/${candidate}" || \
          git ls-remote --exit-code --heads "$git_remote" "$candidate" >/dev/null 2>&1; do
        suffix=$((suffix + 1))
        candidate="${branch}-$(printf '%02d' "$suffix")"
    done

    printf '%s' "$candidate"
}

prepare_base_branch() {
    local git_remote="$1"
    local base_branch="$2"

    log "fetching ${git_remote}/${base_branch}"
    git fetch "$git_remote" "$base_branch"

    if [ "$(current_branch)" != "$base_branch" ]; then
        log "switching to ${base_branch}"
        git switch "$base_branch"
    fi

    log "fast-forwarding ${base_branch}"
    git pull --ff-only "$git_remote" "$base_branch"
}

apply_n8n_update() {
    log "refreshing the n8n source and builder/runtime image pins"
    set_docker_arg "$DOCKERFILE_LOCAL_REPO" "N8N_SOURCE_REF" "$N8N_LATEST_REF"
    set_docker_arg "$DOCKERFILE_LOCAL_REPO" "N8N_SOURCE_SHA" "$N8N_LATEST_SHA"
    set_docker_arg "$DOCKERFILE_LOCAL_REPO" "NODE_BUILDER_IMAGE" "$N8N_LATEST_NODE_IMAGE"
    set_docker_arg "$DOCKERFILE_LOCAL_REPO" "N8N_BASE_IMAGE" "$N8N_LATEST_BASE_IMAGE"
    set_docker_arg "$DOCKERFILE_N8N" "N8N_SOURCE_REF" "$N8N_LATEST_REF"
    set_shell_assignment "$DEPLOY_SCRIPT_PATH" "PROJECT_N8N_VERSION" "$N8N_LATEST_VERSION"
    set_shell_assignment "$DEPLOY_SCRIPT_PATH" "PROJECT_N8N_SOURCE_SHA" "$N8N_LATEST_SHA"
    set_shell_assignment "$ENV_EXAMPLE_PATH" "N8N_VERSION" "$N8N_LATEST_VERSION"
    set_shell_assignment "$ENV_EXAMPLE_PATH" "N8N_SOURCE_REF" "$N8N_LATEST_REF"
    set_shell_assignment "$ENV_EXAMPLE_PATH" "N8N_SOURCE_SHA" "$N8N_LATEST_SHA"
    set_compose_default "$COMPOSE_FILE_PATH" "N8N_SOURCE_REF" "$N8N_LATEST_REF"
    set_compose_default "$COMPOSE_FILE_PATH" "N8N_SOURCE_SHA" "$N8N_LATEST_SHA"
}

apply_openwebui_update() {
    log "refreshing the OpenWebUI release tag and image digest"
    set_docker_arg "$DOCKERFILE_LOCAL_REPO" "OPENWEBUI_VERSION" "$OPENWEBUI_LATEST_VERSION"
    set_docker_arg "$DOCKERFILE_LOCAL_REPO" "OPENWEBUI_IMAGE" "$OPENWEBUI_LATEST_IMAGE"
    set_shell_assignment "$DEPLOY_SCRIPT_PATH" "PROJECT_OPENWEBUI_VERSION" "$OPENWEBUI_LATEST_VERSION"
    set_shell_assignment "$DEPLOY_SCRIPT_PATH" "PROJECT_OPENWEBUI_IMAGE" "$OPENWEBUI_LATEST_IMAGE"
    set_shell_assignment "$ENV_EXAMPLE_PATH" "OPENWEBUI_VERSION" "$OPENWEBUI_LATEST_VERSION"
    set_shell_assignment "$ENV_EXAMPLE_PATH" "OPENWEBUI_IMAGE" "$OPENWEBUI_LATEST_IMAGE"
    set_compose_default "$COMPOSE_FILE_PATH" "OPENWEBUI_VERSION" "$OPENWEBUI_LATEST_VERSION"
    set_compose_default "$COMPOSE_FILE_PATH" "OPENWEBUI_IMAGE" "$OPENWEBUI_LATEST_IMAGE"
}

run_validation() {
    log "running syntax smoke checks"
    "$SMOKE_TEST_PATH" --syntax

    log "running release helper dry-run"
    "$RELEASE_HELPER_PATH" --dry-run </dev/null >/dev/null
}

commit_title_for_selection() {
    printf 'Update %s pins' "$(human_component_list "${SELECTED_COMPONENTS[@]}")"
}

write_pr_body() {
    local body_file="$1"
    local component

    {
        printf '## Summary\n\n'
        for component in "${SELECTED_COMPONENTS[@]}"; do
            component_pr_summary "$component"
        done
        printf '\n## Validation\n\n'
        printf -- "- \`./scripts/smoke-test.sh --syntax\`\n"
        printf -- "- \`./release.sh --dry-run\`\n"
        printf '\n## Notes\n\n'
        printf -- '- This PR is meant to trigger CI against the refreshed upstream pins before anything ships.\n'
    } >"$body_file"
}

stage_changed_files() {
    git add \
        "$DOCKERFILE_LOCAL_REPO" \
        "$DOCKERFILE_N8N" \
        "$DEPLOY_SCRIPT_PATH" \
        "$COMPOSE_FILE_PATH" \
        "$ENV_EXAMPLE_PATH"
}

print_plan() {
    local base_branch="$1"
    local branch_name="$2"
    local component

    cat <<EOF
Update plan
  repo:   $(gh repo view --json nameWithOwner --jq .nameWithOwner)
  branch: ${branch_name:-<not created>}
  base:   $base_branch

Selected updates
EOF

    if [ "${#SELECTED_COMPONENTS[@]}" -eq 0 ]; then
        printf '  <none>\n'
        return
    fi

    for component in "${SELECTED_COMPONENTS[@]}"; do
        printf '  - %s\n' "$(component_label "$component")"
        printf '    current: %s\n' "$(component_current_summary "$component")"
        printf '    latest:  %s\n' "$(component_latest_summary "$component")"
    done
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --all)
            ALL_COMPONENTS=true
            ;;
        --base=*)
            BASE_BRANCH_OVERRIDE="${1#*=}"
            ;;
        --base)
            shift || true
            if [ "$#" -eq 0 ]; then
                err "--base requires a value"
                exit 1
            fi
            BASE_BRANCH_OVERRIDE="$1"
            ;;
        --dry-run)
            DRY_RUN=true
            ;;
        --yes)
            YES=true
            ;;
        --no-push)
            PUSH_CHANGES=false
            OPEN_PR=false
            ;;
        --no-pr)
            OPEN_PR=false
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            validate_component_name "$1"
            REQUESTED_COMPONENTS+=("$1")
            ;;
    esac
    shift
done

require_cmd git
require_cmd python3
require_cmd awk
ensure_gh_ready
ensure_docker_ready

git_remote="$(preferred_remote)"
if [ -z "$git_remote" ]; then
    err "no git remote configured"
    exit 1
fi

discover_n8n_update
discover_openwebui_update

printf 'Available updates\n'
print_component_report n8n
print_component_report openwebui
printf '\n'

build_selection

base_branch="$(default_branch)"
planned_branch=""
if [ "${#SELECTED_COMPONENTS[@]}" -gt 0 ]; then
    planned_branch="$(branch_name_for_selection "$git_remote")"
fi
print_plan "$base_branch" "$planned_branch"
printf '\n'

if [ "$DRY_RUN" = true ]; then
    exit 0
fi

if [ "${#SELECTED_COMPONENTS[@]}" -eq 0 ]; then
    log "nothing selected; exiting"
    exit 0
fi

if ! prompt_yes_no_default "Create the update branch and draft PR?" "yes"; then
    log "update cancelled"
    exit 0
fi

ensure_clean_worktree
prepare_base_branch "$git_remote" "$base_branch"

branch_name="$(branch_name_for_selection "$git_remote")"
log "creating ${branch_name}"
git switch -c "$branch_name"

for component in "${SELECTED_COMPONENTS[@]}"; do
    case "$component" in
        n8n) apply_n8n_update ;;
        openwebui) apply_openwebui_update ;;
        *)
            err "unsupported component: $component"
            exit 1
            ;;
    esac
done

if git diff --quiet; then
    log "no file changes were produced"
    exit 0
fi

run_validation

stage_changed_files

commit_title="$(commit_title_for_selection)"
git commit -m "$commit_title"

pr_url=""
if [ "$PUSH_CHANGES" = true ]; then
    log "pushing ${branch_name}"
    git push -u "$git_remote" "$branch_name"

    if [ "$OPEN_PR" = true ]; then
        pr_body="$(mktemp)"
        trap 'rm -f "$pr_body"' EXIT
        write_pr_body "$pr_body"
        log "opening a draft PR against ${base_branch}"
        pr_url="$(gh pr create \
            --draft \
            --base "$base_branch" \
            --head "$branch_name" \
            --title "$commit_title" \
            --body-file "$pr_body")"
    fi
fi

printf '\nDone\n'
printf '  branch: %s\n' "$branch_name"
printf '  commit: %s\n' "$(current_head)"
if [ "$PUSH_CHANGES" = true ]; then
    printf '  push:   %s/%s\n' "$git_remote" "$branch_name"
else
    printf '  push:   skipped (--no-push)\n'
fi
if [ "$OPEN_PR" = true ]; then
    printf '  pr:     %s\n' "${pr_url:-<created>}"
else
    printf '  pr:     skipped\n'
fi
