#!/usr/bin/env bash
#
# Post-startup n8n configuration: owner setup/reset, credentials, workflows.
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

if [ -f "$PROJECT_DIR/.env" ]; then
    set -a
    # shellcheck source=/dev/null
    source "$PROJECT_DIR/.env"
    set +a
fi

N8N_ADMIN_EMAIL="${N8N_ADMIN_EMAIL:?N8N_ADMIN_EMAIL must be set}"
N8N_ADMIN_PASSWORD="${N8N_ADMIN_PASSWORD:?N8N_ADMIN_PASSWORD must be set}"
POSTGRES_USER="${POSTGRES_USER:-dropzone}"
POSTGRES_DB="${POSTGRES_N8N_DB:-${POSTGRES_DB:-n8n}}"
RESET_OWNER_PASSWORD="${RESET_OWNER_PASSWORD:-false}"

n8n_exec() {
    compose exec -T n8n "$@"
}

postgres_exec() {
    compose exec -T postgres "$@"
}

n8n_api() {
    local method="$1"
    local path="$2"
    shift 2
    case "$method" in
        POST)
            local body="${1:-}"
            n8n_exec wget -q -O- \
                --header='Content-Type: application/json' \
                --post-data="$body" \
                "http://127.0.0.1:5678${path}" 2>/dev/null || true
            ;;
        GET)
            n8n_exec wget -q -O- "http://127.0.0.1:5678${path}" 2>/dev/null || true
            ;;
        *)
            echo "Unsupported n8n_api method: $method" >&2
            return 1
            ;;
    esac
}

sql_escape() {
    printf "%s" "$1" | sed "s/'/''/g"
}

postgres_scalar() {
    postgres_exec psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -At -v ON_ERROR_STOP=1 -c "$1"
}

owner_is_configured() {
    [ "$(postgres_scalar "SELECT value FROM settings WHERE key = 'userManagement.isInstanceOwnerSetUp';")" = "true" ]
}

workflow_exists() {
    local workflow_name
    workflow_name="$(sql_escape "$1")"
    [ "$(postgres_scalar "SELECT COUNT(*) FROM workflow_entity WHERE name = '${workflow_name}';")" -gt 0 ]
}

credential_exists() {
    local credential_name credential_type
    credential_name="$(sql_escape "$1")"
    credential_type="$(sql_escape "$2")"
    [ "$(postgres_scalar "SELECT COUNT(*) FROM credentials_entity WHERE name = '${credential_name}' AND type = '${credential_type}';")" -gt 0 ]
}

owner_email() {
    postgres_scalar "SELECT COALESCE(email, '') FROM \"user\" WHERE \"roleSlug\" = 'global:owner' LIMIT 1;"
}

owner_user_id() {
    postgres_scalar "SELECT id FROM \"user\" WHERE \"roleSlug\" = 'global:owner' LIMIT 1;"
}

owner_password_hash() {
    n8n_exec node -e 'const bcrypt = require("/usr/local/lib/node_modules/n8n/node_modules/bcryptjs"); (async () => { process.stdout.write(await bcrypt.hash(process.argv[1], 10)); })().catch((error) => { console.error(error); process.exit(1); });' "$1"
}

generate_uuid() {
    if command -v python3 >/dev/null 2>&1; then
        python3 - <<'PY'
import uuid
print(uuid.uuid4())
PY
    elif command -v node >/dev/null 2>&1; then
        node -e 'console.log(require("crypto").randomUUID())'
    else
        uuidgen
    fi
}

json_field_from_file() {
    local file_path="$1"
    local field_name="$2"
    if command -v jq >/dev/null 2>&1; then
        jq -r --arg field "$field_name" '.[$field] // ""' "$file_path"
    else
        python3 - "$file_path" "$field_name" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    data = json.load(handle)
value = data.get(sys.argv[2], "")
print(value)
PY
    fi
}

workflow_import_payload() {
    local file_path="$1"
    local workflow_id
    workflow_id="$(generate_uuid)"
    if command -v jq >/dev/null 2>&1; then
        jq -c --arg workflow_id "$workflow_id" '.id = (.id // $workflow_id)' "$file_path"
    else
        python3 - "$file_path" "$workflow_id" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    workflow = json.load(handle)
workflow.setdefault("id", sys.argv[2])
print(json.dumps(workflow))
PY
    fi
}

build_chutes_credential_json() {
    local credential_id
    credential_id="$(generate_uuid)"

    if command -v jq >/dev/null 2>&1; then
        jq -n --arg api_key "$CHUTES_API_KEY" --arg id "$credential_id" '[{
            id: $id,
            name: "Chutes API",
            type: "chutesApi",
            data: {
                apiKey: $api_key,
                environment: "Production"
            }
        }]'
    else
        python3 - "$CHUTES_API_KEY" "$credential_id" <<'PY'
import json
import sys

print(json.dumps([{
    "id": sys.argv[2],
    "name": "Chutes API",
    "type": "chutesApi",
    "data": {
        "apiKey": sys.argv[1],
        "environment": "Production",
    },
}]))
PY
    fi
}

echo "  Configuring break-glass owner ..."

setup_body="$(printf '{"email":"%s","firstName":"Chutes","lastName":"Owner","password":"%s"}' \
    "$N8N_ADMIN_EMAIL" "$N8N_ADMIN_PASSWORD")"
setup_result=""
created_owner=false

if owner_is_configured; then
    echo "    Owner already configured"
    echo "    n8n completed owner setup before the bootstrap step ran"
elif setup_result="$(n8n_api POST /rest/owner/setup "$setup_body")" && [[ "$setup_result" == *'"id"'* ]]; then
    echo "    Owner account created"
    created_owner=true
else
    echo "    ERROR: owner setup failed"
    echo "    $setup_result" | head -5
    exit 1
fi

if [ "$RESET_OWNER_PASSWORD" = true ] && [ "$created_owner" = false ] && owner_is_configured; then
    echo "    Rotating owner password ..."
    password_hash="$(owner_password_hash "$N8N_ADMIN_PASSWORD")"
    postgres_exec psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 \
        -c "UPDATE \"user\" SET password = \$pw\$${password_hash}\$pw\$, email = \$mail\$${N8N_ADMIN_EMAIL}\$mail\$ WHERE \"roleSlug\" = 'global:owner';" >/dev/null
    echo "    Owner password updated"
fi

current_owner_email="$(owner_email)"
if [ -z "$current_owner_email" ]; then
    echo "    ERROR: owner email is still empty after configuration"
    exit 1
fi

owner_user_id_value="$(owner_user_id)"
if [ -z "$owner_user_id_value" ]; then
    echo "    ERROR: owner user ID is still empty after configuration"
    exit 1
fi

if [ -n "${CHUTES_API_KEY:-}" ]; then
    echo "  Ensuring Chutes API credential exists ..."
    if credential_exists "Chutes API" "chutesApi"; then
        echo "    Chutes API credential already present"
    else
        build_chutes_credential_json | compose exec -T n8n \
            sh -c "cat > /tmp/creds.json && n8n import:credentials --input=/tmp/creds.json && rm -f /tmp/creds.json"
        echo "    Chutes API credential imported"
    fi
fi

WORKFLOW_DIR="$PROJECT_DIR/workflows"
if [ -d "$WORKFLOW_DIR" ] && ls "$WORKFLOW_DIR"/*.json >/dev/null 2>&1; then
    echo "  Ensuring starter workflows exist ..."

    for workflow_file in "$WORKFLOW_DIR"/*.json; do
        workflow_name="$(json_field_from_file "$workflow_file" name)"
        if [ -z "$workflow_name" ]; then
            echo "    WARNING: could not read workflow name from $(basename "$workflow_file")"
            continue
        fi

        if workflow_exists "$workflow_name"; then
            echo "    Workflow already present: $workflow_name"
            continue
        fi

        workflow_import_payload "$workflow_file" | compose exec -T n8n \
            sh -c "cat > /tmp/workflow.json && n8n import:workflow --input=/tmp/workflow.json --userId=${owner_user_id_value} && rm -f /tmp/workflow.json"
        echo "    Imported workflow: $workflow_name"
    done
fi

echo "  Configuration complete."
