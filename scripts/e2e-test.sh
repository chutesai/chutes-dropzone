#!/usr/bin/env bash
#
# Destructive end-to-end test for chutes-n8n-local.
# Uses a test local Chutes IdP and recreates the local stack from scratch.
#
set -euo pipefail

trap 'echo "e2e-test.sh FAILED at line $LINENO (exit $?)" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
E2E_TRAFFIC_MODE="${E2E_TRAFFIC_MODE:-direct}"
COMPOSE_FILES="$PROJECT_DIR/docker-compose.yml:$PROJECT_DIR/docker-compose.local.yml:$PROJECT_DIR/docker-compose.test.yml"
if [ "$E2E_TRAFFIC_MODE" = "e2ee-proxy" ]; then
    COMPOSE_FILES="${COMPOSE_FILES}:$PROJECT_DIR/docker-compose.traffic-proxy.yml"
fi
COOKIE_DIR="$(mktemp -d)"
BACKUP_DIR="$(mktemp -d)"
ENV_BACKUP="$BACKUP_DIR/.env.backup"
CADDY_BACKUP="$BACKUP_DIR/Caddyfile.backup"
LOCAL_PROXY_BACKUP="$BACKUP_DIR/local-proxy.nginx.conf.backup"
ORIGINAL_ENV_PRESENT=false
ORIGINAL_CADDY_PRESENT=false
ORIGINAL_LOCAL_PROXY_PRESENT=false

compose() {
    local file
    local old_ifs="$IFS"
    local -a args=()

    IFS=':' read -r -a compose_files <<< "$COMPOSE_FILES"
    IFS="$old_ifs"

    for file in "${compose_files[@]}"; do
        args+=(-f "$file")
    done

    docker compose "${args[@]}" "$@"
}

curl_edge() {
    curl \
        --resolve "${DROPZONE_HOST:-e2ee-local-proxy.chutes.dev}:443:127.0.0.1" \
        --resolve "${DROPZONE_HOST:-e2ee-local-proxy.chutes.dev}:80:127.0.0.1" \
        --max-time 30 \
        "$@"
}

cleanup() {
    set +e
    CHUTES_COMPOSE_FILES="$COMPOSE_FILES" "$PROJECT_DIR/deploy.sh" --down >/dev/null 2>&1 || true
    compose down -v --remove-orphans >/dev/null 2>&1 || true

    if [ "$ORIGINAL_ENV_PRESENT" = true ]; then
        cp "$ENV_BACKUP" "$PROJECT_DIR/.env"
    else
        rm -f "$PROJECT_DIR/.env"
    fi

    if [ "$ORIGINAL_CADDY_PRESENT" = true ]; then
        cp "$CADDY_BACKUP" "$PROJECT_DIR/conf/Caddyfile"
    else
        rm -f "$PROJECT_DIR/conf/Caddyfile"
    fi

    if [ "$ORIGINAL_LOCAL_PROXY_PRESENT" = true ]; then
        cp "$LOCAL_PROXY_BACKUP" "$PROJECT_DIR/conf/local-proxy.nginx.conf"
    else
        rm -f "$PROJECT_DIR/conf/local-proxy.nginx.conf"
    fi

    rm -rf "$COOKIE_DIR" "$BACKUP_DIR"
}

trap cleanup EXIT

assert_eq() {
    local actual="$1"
    local expected="$2"
    local message="$3"

    if [ "$actual" != "$expected" ]; then
        echo "FAIL: $message" >&2
        echo "  expected: $expected" >&2
        echo "  actual:   $actual" >&2
        exit 1
    fi
}

assert_nonempty() {
    local value="$1"
    local message="$2"

    if [ -z "$value" ]; then
        echo "FAIL: $message" >&2
        exit 1
    fi
}

assert_gt() {
    local actual="$1"
    local minimum="$2"
    local message="$3"

    if [ "$actual" -le "$minimum" ]; then
        echo "FAIL: $message" >&2
        echo "  expected greater than: $minimum" >&2
        echo "  actual:               $actual" >&2
        exit 1
    fi
}

extract_location() {
    python3 - "$1" <<'PY'
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as handle:
    for line in handle:
        if line.lower().startswith("location:"):
            print(line.split(":", 1)[1].strip())
            break
PY
}

extract_state_from_location() {
    python3 - "$1" <<'PY'
import sys
from urllib.parse import urlparse, parse_qs

location = sys.argv[1]
print(parse_qs(urlparse(location).query).get("state", [""])[0])
PY
}

query_scalar() {
    compose exec -T postgres psql -U "${POSTGRES_USER:-dropzone}" -d "${POSTGRES_N8N_DB:-${POSTGRES_DB:-n8n}}" -At -v ON_ERROR_STOP=1 -c "$1"
}

load_env() {
    set -a
    # shellcheck source=/dev/null
    source "$PROJECT_DIR/.env"
    set +a
}

owner_login() {
    curl_edge -sk -H 'Content-Type: application/json' \
        -H 'browser-id: e2e-owner-browser' \
        -d "$(printf '{"emailOrLdapLoginId":"%s","password":"%s"}' "$N8N_ADMIN_EMAIL" "$N8N_ADMIN_PASSWORD")" \
        "https://${DROPZONE_HOST}/n8n/rest/login"
}

authenticated_node_types() {
    local cookie_file="$1"
    local browser_id="$2"

    curl_edge -sk -b "$cookie_file" \
        -H 'Content-Type: application/json' \
        -H "browser-id: ${browser_id}" \
        -d '{"nodeInfos":[{"name":"CUSTOM.chutes","version":1}]}' \
        "https://${DROPZONE_HOST}/n8n/rest/node-types"
}

openwebui_account_summary() {
    local cookie_file="$1"
    local token=""

    if [ -f "$cookie_file" ]; then
        token="$(awk '/\ttoken\t/{print $NF}' "$cookie_file" | tail -1)"
    fi

    if [ -n "$token" ]; then
        curl_edge -sk \
            -H "Authorization: Bearer ${token}" \
            -H 'Accept: application/json' \
            "https://${DROPZONE_HOST}/api/v1/dropzone/account-summary"
    else
        curl_edge -sk -b "$cookie_file" \
            -H 'Accept: application/json' \
            "https://${DROPZONE_HOST}/api/v1/dropzone/account-summary"
    fi
}

n8n_account_summary() {
    local cookie_file="$1"
    local browser_id="$2"

    curl_edge -sk -b "$cookie_file" \
        -H "browser-id: ${browser_id}" \
        -H 'Accept: application/json' \
        "https://${DROPZONE_HOST}/n8n/rest/sso/chutes/account-summary"
}

complete_openwebui_sso_login() {
    local cookie_file="$1"
    local headers_file="$2"
    local final_url_file="$3"
    local location state callback_url callback_headers

    curl_edge -sk -o /dev/null -D "$headers_file" -c "$cookie_file" \
        "https://${DROPZONE_HOST}/oauth/oidc/login"

    location="$(extract_location "$headers_file")"
    assert_nonempty "$location" "missing OpenWebUI OAuth redirect location"

    state="$(extract_state_from_location "$location")"
    assert_nonempty "$state" "missing OpenWebUI OAuth state"

    callback_url="https://${DROPZONE_HOST}/oauth/oidc/callback?code=member-code&state=${state}"
    curl_edge -skL -o /dev/null -c "$cookie_file" -b "$cookie_file" \
        -w '%{url_effective}' \
        "$callback_url" >"$final_url_file"
}

complete_sso_login() {
    local code="$1"
    local cookie_file="$2"
    local headers_file="$3"
    local callback_headers="$4"
    local browser_id="$5"
    local location state

    curl_edge -sk -o /dev/null -D "$headers_file" -c "$cookie_file" \
        -H "browser-id: ${browser_id}" \
        "https://${DROPZONE_HOST}/n8n/rest/sso/chutes/login?redirect=/workflows"

    location="$(extract_location "$headers_file")"
    if [ -z "$location" ]; then
        echo "FAIL: missing SSO redirect location" >&2
        echo "  login response headers:" >&2
        sed 's/\r$//' "$headers_file" >&2
        exit 1
    fi
    assert_nonempty "$location" "missing SSO redirect location"
    state="$(extract_state_from_location "$location")"
    assert_nonempty "$state" "missing SSO state"
    printf '%s' "$location" | grep -q "redirect_uri=https%3A%2F%2F${DROPZONE_HOST}%2Frest%2Fsso%2Fchutes%2Fcallback" || {
        echo "FAIL: SSO login did not request the root callback alias" >&2
        echo "  location: $location" >&2
        exit 1
    }

    curl_edge -sk -o /dev/null -D "$callback_headers" -b "$cookie_file" -c "$cookie_file" \
        -H "browser-id: ${browser_id}" \
        "https://${DROPZONE_HOST}/rest/sso/chutes/callback?code=${code}&state=${state}"
}

user_role_for_subject() {
    local subject="$1"
    query_scalar "SELECT u.\"roleSlug\" FROM auth_identity ai JOIN \"user\" u ON u.id = ai.\"userId\" WHERE ai.\"providerType\" = 'chutes' AND ai.\"providerId\" = '$(printf "%s" "$subject" | sed "s/'/''/g")';"
}

user_count_for_subject() {
    local subject="$1"
    query_scalar "SELECT COUNT(*) FROM auth_identity WHERE \"providerType\" = 'chutes' AND \"providerId\" = '$(printf "%s" "$subject" | sed "s/'/''/g")';"
}

workflow_count() {
    query_scalar "SELECT COUNT(*) FROM workflow_entity WHERE name IN ('Chutes AI Agent Demo', 'Chutes Nodes Showcase');"
}

credential_count() {
    query_scalar "SELECT COUNT(*) FROM credentials_entity WHERE name = 'Chutes API' AND type = 'chutesApi';"
}

managed_credential_count_for_subject() {
    local subject="$1"

    query_scalar "SELECT COUNT(*) \
FROM auth_identity ai \
JOIN \"user\" u ON u.id = ai.\"userId\" \
JOIN project_relation pr ON pr.\"userId\" = u.id AND pr.role = 'project:personalOwner' \
JOIN shared_credentials sc ON sc.\"projectId\" = pr.\"projectId\" AND sc.role = 'credential:owner' \
JOIN credentials_entity ce ON ce.id = sc.\"credentialsId\" \
WHERE ai.\"providerType\" = 'chutes' \
  AND ai.\"providerId\" = '$(printf "%s" "$subject" | sed "s/'/''/g")' \
  AND ce.type = 'chutesApi' \
  AND ce.name = 'Chutes SSO';"
}

managed_credential_id_for_subject() {
    local subject="$1"

    query_scalar "SELECT ce.id \
FROM auth_identity ai \
JOIN \"user\" u ON u.id = ai.\"userId\" \
JOIN project_relation pr ON pr.\"userId\" = u.id AND pr.role = 'project:personalOwner' \
JOIN shared_credentials sc ON sc.\"projectId\" = pr.\"projectId\" AND sc.role = 'credential:owner' \
JOIN credentials_entity ce ON ce.id = sc.\"credentialsId\" \
WHERE ai.\"providerType\" = 'chutes' \
  AND ai.\"providerId\" = '$(printf "%s" "$subject" | sed "s/'/''/g")' \
  AND ce.type = 'chutesApi' \
  AND ce.name = 'Chutes SSO' \
LIMIT 1;"
}

managed_credential_json_for_subject() {
    local subject="$1"
    local credential_id

    credential_id="$(managed_credential_id_for_subject "$subject")"
    assert_nonempty "$credential_id" "missing managed Chutes credential id for subject ${subject}"

    compose exec -T n8n sh -lc "
        tmp_file=\$(mktemp)
        log_file=\$(mktemp)
        if ! n8n export:credentials --id='${credential_id}' --decrypted --output=\"\$tmp_file\" >\"\$log_file\" 2>&1; then
            cat \"\$log_file\" >&2
            rm -f \"\$tmp_file\" \"\$log_file\"
            exit 1
        fi
        if [ ! -s \"\$tmp_file\" ]; then
            echo 'credential export produced an empty payload' >&2
            cat \"\$log_file\" >&2
            rm -f \"\$tmp_file\" \"\$log_file\"
            exit 1
        fi
        cat \"\$tmp_file\"
        rm -f \"\$tmp_file\" \"\$log_file\"
    " | python3 -c '
import json
import sys

credential_id = str(sys.argv[1])
exported = json.load(sys.stdin)
credentials = exported if isinstance(exported, list) else [exported]

for credential in credentials:
    if str(credential.get("id", "")) == credential_id:
        print(json.dumps(credential))
        raise SystemExit(0)

raise SystemExit(f"managed credential export did not include credential id {credential_id}")
' "$credential_id"
}

managed_credential_field_for_subject() {
    local subject="$1"
    local field_name="$2"

    managed_credential_json_for_subject "$subject" | python3 -c '
import json
import sys

field_name = sys.argv[1]
credential = json.load(sys.stdin)
print(credential.get("data", {}).get(field_name, ""))
' "$field_name"
}

test_managed_credential() {
    local subject="$1"
    local cookie_file="$2"
    local browser_id="$3"
    local credential_json payload

    credential_json="$(managed_credential_json_for_subject "$subject")"
    payload="$(python3 - "$credential_json" <<'PY'
import json
import sys

credential = json.loads(sys.argv[1])
print(json.dumps({"credentials": credential}))
PY
)"

    curl_edge -sk -b "$cookie_file" \
        -H 'Content-Type: application/json' \
        -H "browser-id: ${browser_id}" \
        -d "$payload" \
        "https://${DROPZONE_HOST}/n8n/rest/credentials/test"
}

load_image_chutes() {
    local subject="$1"
    local cookie_file="$2"
    local browser_id="$3"
    local credential_id payload

    credential_id="$(managed_credential_id_for_subject "$subject")"
    assert_nonempty "$credential_id" "missing managed Chutes credential id for subject ${subject}"

    payload="$(python3 - "$credential_id" <<'PY'
import json
import sys

credential_id = sys.argv[1]
print(json.dumps({
    "credentials": {
        "chutesApi": {
            "id": credential_id,
            "name": "Chutes SSO",
        }
    },
    "currentNodeParameters": {
        "resource": "imageGeneration",
        "chuteUrl": "",
        "operation": "generate",
        "prompt": "",
        "size": "1024x1024",
        "n": 1,
        "additionalOptions": {},
    },
    "nodeTypeAndVersion": {
        "name": "CUSTOM.chutes",
        "version": 1,
    },
    "methodName": "getImageChutes",
    "path": "chuteUrl",
}))
PY
)"

    curl_edge -sk -b "$cookie_file" \
        -H 'Content-Type: application/json' \
        -H "browser-id: ${browser_id}" \
        -d "$payload" \
        "https://${DROPZONE_HOST}/n8n/rest/dynamic-node-parameters/options"
}

if [ -f "$PROJECT_DIR/.env" ]; then
    cp "$PROJECT_DIR/.env" "$ENV_BACKUP"
    ORIGINAL_ENV_PRESENT=true
fi

if [ -f "$PROJECT_DIR/conf/Caddyfile" ]; then
    cp "$PROJECT_DIR/conf/Caddyfile" "$CADDY_BACKUP"
    ORIGINAL_CADDY_PRESENT=true
fi

if [ -f "$PROJECT_DIR/conf/local-proxy.nginx.conf" ]; then
    cp "$PROJECT_DIR/conf/local-proxy.nginx.conf" "$LOCAL_PROXY_BACKUP"
    ORIGINAL_LOCAL_PROXY_PRESENT=true
fi

rm -f "$PROJECT_DIR/.env" "$PROJECT_DIR/conf/Caddyfile" "$PROJECT_DIR/conf/local-proxy.nginx.conf"
compose down -v --remove-orphans >/dev/null 2>&1 || true

export INSTALL_MODE="local"
export CHUTES_COMPOSE_FILES="$COMPOSE_FILES"
export CHUTES_TRAFFIC_MODE="$E2E_TRAFFIC_MODE"
export ALLOW_NON_CONFIDENTIAL="${ALLOW_NON_CONFIDENTIAL:-false}"
export CHUTES_SSO_PROXY_BYPASS="${CHUTES_SSO_PROXY_BYPASS:-false}"
export DROPZONE_HOST="e2ee-local-proxy.chutes.dev"
export N8N_HOST="$DROPZONE_HOST"
export CHUTES_OAUTH_CLIENT_ID="test-chutes-client"
export CHUTES_OAUTH_CLIENT_SECRET='test secret with spaces $ and # and "quotes"'
export CHUTES_IDP_BASE_URL="http://test-chutes-idp:8080"
export CHUTES_ADMIN_USERNAMES="admin-user"
export CHUTES_API_KEY="cpk_test_e2e.0123456789abcdef.abcdef0123456789"
export SKIP_CHUTES_MODEL_VALIDATION="true"

"$PROJECT_DIR/deploy.sh" --force-all
load_env

landing_html="$(curl_edge -sk "https://${DROPZONE_HOST}/")"
if [[ "$landing_html" != *"/chat/"* || "$landing_html" != *"/n8n/"* ]]; then
    echo "FAIL: landing page did not render the expected launch links" >&2
    exit 1
fi

landing_css_headers="$(curl_edge -skI "https://${DROPZONE_HOST}/_dropzone/styles.css")"
if ! printf '%s' "$landing_css_headers" | grep -qi '^Content-Type: text/css'; then
    echo "FAIL: landing stylesheet is not served as text/css" >&2
    printf '%s\n' "$landing_css_headers" >&2
    exit 1
fi

landing_headers="$(curl_edge -skI "https://${DROPZONE_HOST}/")"
if ! printf '%s' "$landing_headers" | grep -qi '^Cache-Control: no-store'; then
    echo "FAIL: landing HTML is missing Cache-Control: no-store" >&2
    printf '%s\n' "$landing_headers" >&2
    exit 1
fi

auth_headers="$(curl_edge -skI "https://${DROPZONE_HOST}/auth?redirect=%2Fchat%2F")"
if ! printf '%s' "$auth_headers" | grep -qi '^HTTP/.* 200'; then
    echo "FAIL: /auth did not return the OpenWebUI login page" >&2
    printf '%s\n' "$auth_headers" >&2
    exit 1
fi

oauth_login_headers="$(curl_edge -skD- "https://${DROPZONE_HOST}/oauth/oidc/login" -o /dev/null)"
if ! printf '%s' "$oauth_login_headers" | grep -qi '^HTTP/.* 30[27]'; then
    echo "FAIL: /oauth/oidc/login did not redirect to the IDP" >&2
    printf '%s\n' "$oauth_login_headers" >&2
    exit 1
fi

if ! printf '%s' "$oauth_login_headers" | grep -qi "redirect_uri=https%3A%2F%2F${DROPZONE_HOST}%2Foauth%2Foidc%2Fcallback"; then
    echo "FAIL: OpenWebUI is not requesting the root OAuth callback alias" >&2
    printf '%s\n' "$oauth_login_headers" >&2
    exit 1
fi

chat_html_file="$COOKIE_DIR/chat.html"
chat_status="$(curl_edge -sk -o "$chat_html_file" -w '%{http_code}' "https://${DROPZONE_HOST}/chat/" || echo 000)"
if [[ "$chat_status" != "302" ]]; then
    echo "FAIL: OpenWebUI /chat/ entrypoint did not redirect (status ${chat_status})" >&2
    exit 1
fi

if ! curl_edge -skI "https://${DROPZONE_HOST}/chat/" | grep -qi "^location: .*/c/new\\|^location: /c/new"; then
    echo "FAIL: OpenWebUI /chat/ entrypoint is not redirecting to /c/new" >&2
    exit 1
fi

chat_native_html="$(curl_edge -sk "https://${DROPZONE_HOST}/c/new")"
if [[ "$chat_native_html" != *'href="/_app/'* || "$chat_native_html" != *'src="/static/'* || "$chat_native_html" == *'base: "/chat"'* ]]; then
    echo "FAIL: OpenWebUI frontend HTML is not using native root routes" >&2
    exit 1
fi

n8n_status="$(curl_edge -sk -o /dev/null -w '%{http_code}' "https://${DROPZONE_HOST}/n8n/signin" || echo 000)"
case "$n8n_status" in
    200|302|303|307|308) ;;
    *)
        echo "FAIL: n8n is not reachable through /n8n/ (status ${n8n_status})" >&2
        exit 1
        ;;
esac

original_owner_password="$N8N_ADMIN_PASSWORD"
original_encryption_key="$N8N_ENCRYPTION_KEY"
original_postgres_password="$POSTGRES_PASSWORD"

owner_response="$(owner_login)"
if [[ "$owner_response" != *'"id"'* ]]; then
    echo "FAIL: break-glass owner login failed after deploy" >&2
    echo "$owner_response" >&2
    exit 1
fi

"$SCRIPT_DIR/smoke-test.sh"

member_cookie="$COOKIE_DIR/member.cookies"
member_headers="$COOKIE_DIR/member.headers"
member_callback_headers="$COOKIE_DIR/member.callback.headers"
complete_sso_login "member-code" "$member_cookie" "$member_headers" "$member_callback_headers" "e2e-member-browser"

member_session_check="$(authenticated_node_types "$member_cookie" "e2e-member-browser")"
if [[ "$member_session_check" != *'"displayName":"Chutes"'* ]]; then
    echo "FAIL: member SSO login did not create an authenticated n8n session" >&2
    echo "$member_session_check" >&2
    exit 1
fi

assert_eq "$(user_role_for_subject "sub-member")" "global:member" "member SSO user should be provisioned as global:member"
assert_eq "$(user_count_for_subject "sub-member")" "1" "member SSO identity should be created exactly once"
assert_eq "$(managed_credential_count_for_subject "sub-member")" "1" "member SSO login should create exactly one managed Chutes credential"

member_refresh_before="$(managed_credential_field_for_subject "sub-member" "refreshToken")"
member_session_before="$(managed_credential_field_for_subject "sub-member" "sessionToken")"
assert_eq "$member_refresh_before" "refresh:member-code:0" "member SSO credential should start with the initial refresh token"
assert_eq "$member_session_before" "token:member-code" "member SSO credential should start with the initial session token"

sleep 1
member_credential_test="$(test_managed_credential "sub-member" "$member_cookie" "e2e-member-browser")"
if [[ "$member_credential_test" != *'"status":"OK"'* && "$member_credential_test" != *'"status":"Success"'* ]]; then
    echo "FAIL: member credential test did not succeed" >&2
    echo "$member_credential_test" >&2
    exit 1
fi

member_refresh_after="$(managed_credential_field_for_subject "sub-member" "refreshToken")"
member_session_after="$(managed_credential_field_for_subject "sub-member" "sessionToken")"
assert_eq "$member_refresh_after" "refresh:member-code:1" "credential test should persist the rotated refresh token"
assert_eq "$member_session_after" "token:member-code:refresh:1" "credential test should persist the rotated session token"

member_n8n_summary="$(n8n_account_summary "$member_cookie" "e2e-member-browser")"
MEMBER_N8N_SUMMARY="$member_n8n_summary" python3 - <<'PY'
import json
import os

raw = os.environ["MEMBER_N8N_SUMMARY"]
payload = json.loads(raw)
summary = payload.get("data", payload)
if "username" not in summary:
    raise SystemExit(f"n8n account summary missing 'username': {raw[:500]}")
assert summary["username"] == "member-user"
assert summary["tier"] == "enterprise"
assert summary["tierLabel"] == "Enterprise"
assert abs(summary["quota"]["used"] - 1284.9) < 0.01
assert abs(summary["quota"]["limit"] - 5001) < 0.01
assert summary["links"]["chatUrl"] == "/chat/"
assert summary["links"]["n8nUrl"] == "/n8n/"
PY

member_openwebui_cookie="$COOKIE_DIR/member-openwebui.cookies"
member_openwebui_headers="$COOKIE_DIR/member-openwebui.headers"
member_openwebui_final_url="$COOKIE_DIR/member-openwebui.final-url"
complete_openwebui_sso_login "$member_openwebui_cookie" "$member_openwebui_headers" "$member_openwebui_final_url"
if ! grep -Eq '/(home|auth)' "$member_openwebui_final_url"; then
    echo "FAIL: OpenWebUI SSO did not finish on an app route" >&2
    cat "$member_openwebui_final_url" >&2
    exit 1
fi

if [ ! -s "$member_openwebui_cookie" ] || ! grep -q 'token' "$member_openwebui_cookie" 2>/dev/null; then
    echo "DEBUG: OpenWebUI cookie jar content:" >&2
    cat "$member_openwebui_cookie" >&2 || echo "(empty)" >&2
fi
member_openwebui_summary="$(openwebui_account_summary "$member_openwebui_cookie")"
MEMBER_OPENWEBUI_SUMMARY="$member_openwebui_summary" python3 - <<'PY'
import json
import os

raw = os.environ["MEMBER_OPENWEBUI_SUMMARY"]
summary = json.loads(raw)
if "username" not in summary:
    raise SystemExit(f"account summary missing 'username': {raw[:500]}")
assert summary["username"] == "member-user", f"expected member-user, got {summary['username']}"
assert summary["tier"] == "enterprise"
assert summary["tierLabel"] == "Enterprise"
assert abs(summary["quota"]["used"] - 1284.9) < 0.01
assert abs(summary["quota"]["limit"] - 5001) < 0.01
assert summary["links"]["accountUrl"] == "https://chutes.ai/app/api/billing-balance#daily-quota-usage"
assert summary["links"]["homeUrl"] == "https://chutes.ai/"
PY

member_cookie_2="$COOKIE_DIR/member-repeat.cookies"
member_headers_2="$COOKIE_DIR/member-repeat.headers"
member_callback_headers_2="$COOKIE_DIR/member-repeat.callback.headers"
complete_sso_login "member-code" "$member_cookie_2" "$member_headers_2" "$member_callback_headers_2" "e2e-member-browser"
assert_eq "$(user_count_for_subject "sub-member")" "1" "repeat member SSO login should reuse the same identity"
assert_eq "$(managed_credential_count_for_subject "sub-member")" "1" "repeat member SSO login should reuse the same managed Chutes credential"

admin_cookie="$COOKIE_DIR/admin.cookies"
admin_headers="$COOKIE_DIR/admin.headers"
admin_callback_headers="$COOKIE_DIR/admin.callback.headers"
complete_sso_login "admin-code" "$admin_cookie" "$admin_headers" "$admin_callback_headers" "e2e-admin-browser"

admin_session_check="$(authenticated_node_types "$admin_cookie" "e2e-admin-browser")"
if [[ "$admin_session_check" != *'"displayName":"Chutes"'* ]]; then
    echo "FAIL: admin SSO login did not create an authenticated n8n session" >&2
    echo "$admin_session_check" >&2
    exit 1
fi

assert_eq "$(user_role_for_subject "sub-admin")" "global:admin" "allowlisted SSO user should be promoted to global:admin"
assert_eq "$(managed_credential_count_for_subject "sub-admin")" "1" "admin SSO login should create exactly one managed Chutes credential"
assert_eq "$(credential_count)" "1" "deploy should import exactly one Chutes API credential"
assert_eq "$(workflow_count)" "2" "deploy should import the two starter workflows exactly once"

"$PROJECT_DIR/deploy.sh" --force
load_env

assert_eq "$N8N_ADMIN_PASSWORD" "$original_owner_password" "--force must preserve the break-glass owner password"
assert_eq "$N8N_ENCRYPTION_KEY" "$original_encryption_key" "--force must preserve N8N_ENCRYPTION_KEY"
assert_eq "$POSTGRES_PASSWORD" "$original_postgres_password" "--force must preserve POSTGRES_PASSWORD"

owner_response_after_force="$(owner_login)"
if [[ "$owner_response_after_force" != *'"id"'* ]]; then
    echo "FAIL: break-glass owner login failed after --force" >&2
    echo "$owner_response_after_force" >&2
    exit 1
fi

assert_eq "$(credential_count)" "1" "--force must not duplicate the Chutes API credential"
assert_eq "$(managed_credential_count_for_subject "sub-member")" "1" "--force must not duplicate the member managed Chutes credential"
assert_eq "$(managed_credential_count_for_subject "sub-admin")" "1" "--force must not duplicate the admin managed Chutes credential"
assert_eq "$(workflow_count)" "2" "--force must not duplicate starter workflows"

"$SCRIPT_DIR/smoke-test.sh"

echo "E2E PASS: native Chutes SSO, local e2ee-proxy TLS, deploy idempotency, and custom nodes validated."
