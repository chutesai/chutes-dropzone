#!/usr/bin/env sh
set -eu

N8N_DB="${POSTGRES_N8N_DB:-${POSTGRES_DB:-n8n}}"
OWUI_DB="${POSTGRES_OPENWEBUI_DB:-openwebui}"
N8N_USER="${POSTGRES_N8N_USER:-${POSTGRES_USER}}"
N8N_PASS="${POSTGRES_N8N_PASSWORD:-${POSTGRES_PASSWORD}}"
OWUI_USER="${POSTGRES_OPENWEBUI_USER:-${POSTGRES_USER}}"
OWUI_PASS="${POSTGRES_OPENWEBUI_PASSWORD:-${POSTGRES_PASSWORD}}"

psql -v ON_ERROR_STOP=1 \
  -v postgres_user="$POSTGRES_USER" \
  -v n8n_db="$N8N_DB" \
  -v owui_db="$OWUI_DB" \
  -v n8n_user="$N8N_USER" \
  -v n8n_pass="$N8N_PASS" \
  -v owui_user="$OWUI_USER" \
  -v owui_pass="$OWUI_PASS" \
  --username "$POSTGRES_USER" \
  --dbname postgres <<'EOSQL'
-- Create databases
SELECT format('CREATE DATABASE %I', :'n8n_db')
WHERE NOT EXISTS (
  SELECT FROM pg_database WHERE datname = :'n8n_db'
)\gexec

SELECT format('CREATE DATABASE %I', :'owui_db')
WHERE NOT EXISTS (
  SELECT FROM pg_database WHERE datname = :'owui_db'
)\gexec

-- Create per-service roles if they differ from the superuser
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'n8n_user', :'n8n_pass')
WHERE :'n8n_user' <> :'postgres_user'
  AND NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'n8n_user')
\gexec

SELECT format('GRANT ALL PRIVILEGES ON DATABASE %I TO %I', :'n8n_db', :'n8n_user')
WHERE :'n8n_user' <> :'postgres_user'
\gexec

SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'owui_user', :'owui_pass')
WHERE :'owui_user' <> :'postgres_user'
  AND NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'owui_user')
\gexec

SELECT format('GRANT ALL PRIVILEGES ON DATABASE %I TO %I', :'owui_db', :'owui_user')
WHERE :'owui_user' <> :'postgres_user'
\gexec
EOSQL

# Grant schema permissions (required on PostgreSQL 15+ where public schema
# is no longer writable by non-owners) and revoke cross-database access.
if [ "${N8N_USER}" != "${POSTGRES_USER}" ]; then
  psql -v ON_ERROR_STOP=1 \
    -v postgres_user="$POSTGRES_USER" \
    -v dbname="$N8N_DB" \
    -v role="$N8N_USER" \
    --username "$POSTGRES_USER" --dbname "$N8N_DB" <<'EOSQL'
SELECT format('GRANT ALL ON SCHEMA public TO %I', :'role')
WHERE :'role' <> :'postgres_user'
\gexec
EOSQL
  psql -v ON_ERROR_STOP=1 \
    -v postgres_user="$POSTGRES_USER" \
    -v dbname="$OWUI_DB" \
    -v role="$N8N_USER" \
    --username "$POSTGRES_USER" --dbname "$OWUI_DB" <<'EOSQL'
SELECT format('REVOKE ALL ON DATABASE %I FROM %I', :'dbname', :'role')
WHERE :'role' <> :'postgres_user'
\gexec
EOSQL
fi
if [ "${OWUI_USER}" != "${POSTGRES_USER}" ]; then
  psql -v ON_ERROR_STOP=1 \
    -v postgres_user="$POSTGRES_USER" \
    -v dbname="$OWUI_DB" \
    -v role="$OWUI_USER" \
    --username "$POSTGRES_USER" --dbname "$OWUI_DB" <<'EOSQL'
SELECT format('GRANT ALL ON SCHEMA public TO %I', :'role')
WHERE :'role' <> :'postgres_user'
\gexec
EOSQL
  psql -v ON_ERROR_STOP=1 \
    -v postgres_user="$POSTGRES_USER" \
    -v dbname="$N8N_DB" \
    -v role="$OWUI_USER" \
    --username "$POSTGRES_USER" --dbname "$N8N_DB" <<'EOSQL'
SELECT format('REVOKE ALL ON DATABASE %I FROM %I', :'dbname', :'role')
WHERE :'role' <> :'postgres_user'
\gexec
EOSQL
fi
