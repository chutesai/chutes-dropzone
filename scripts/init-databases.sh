#!/usr/bin/env sh
set -eu

N8N_DB="${POSTGRES_N8N_DB:-${POSTGRES_DB:-n8n}}"
OWUI_DB="${POSTGRES_OPENWEBUI_DB:-openwebui}"
N8N_USER="${POSTGRES_N8N_USER:-${POSTGRES_USER}}"
N8N_PASS="${POSTGRES_N8N_PASSWORD:-${POSTGRES_PASSWORD}}"
OWUI_USER="${POSTGRES_OPENWEBUI_USER:-${POSTGRES_USER}}"
OWUI_PASS="${POSTGRES_OPENWEBUI_PASSWORD:-${POSTGRES_PASSWORD}}"

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres <<-EOSQL
  -- Create databases
  SELECT 'CREATE DATABASE ${N8N_DB}'
  WHERE NOT EXISTS (
    SELECT FROM pg_database WHERE datname = '${N8N_DB}'
  )\gexec

  SELECT 'CREATE DATABASE ${OWUI_DB}'
  WHERE NOT EXISTS (
    SELECT FROM pg_database WHERE datname = '${OWUI_DB}'
  )\gexec

  -- Create per-service roles if they differ from the superuser
  DO \$\$
  BEGIN
    IF '${N8N_USER}' <> '${POSTGRES_USER}' THEN
      IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${N8N_USER}') THEN
        CREATE ROLE ${N8N_USER} LOGIN PASSWORD '${N8N_PASS}';
      END IF;
      GRANT ALL PRIVILEGES ON DATABASE ${N8N_DB} TO ${N8N_USER};
    END IF;

    IF '${OWUI_USER}' <> '${POSTGRES_USER}' THEN
      IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${OWUI_USER}') THEN
        CREATE ROLE ${OWUI_USER} LOGIN PASSWORD '${OWUI_PASS}';
      END IF;
      GRANT ALL PRIVILEGES ON DATABASE ${OWUI_DB} TO ${OWUI_USER};
    END IF;
  END
  \$\$;
EOSQL

# Grant schema permissions (required on PostgreSQL 15+ where public schema
# is no longer writable by non-owners) and revoke cross-database access.
if [ "${N8N_USER}" != "${POSTGRES_USER}" ]; then
  psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "${N8N_DB}" \
    -c "GRANT ALL ON SCHEMA public TO ${N8N_USER};"
  psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "${OWUI_DB}" \
    -c "REVOKE ALL ON DATABASE ${OWUI_DB} FROM ${N8N_USER};" 2>/dev/null || true
fi
if [ "${OWUI_USER}" != "${POSTGRES_USER}" ]; then
  psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "${OWUI_DB}" \
    -c "GRANT ALL ON SCHEMA public TO ${OWUI_USER};"
  psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "${N8N_DB}" \
    -c "REVOKE ALL ON DATABASE ${N8N_DB} FROM ${OWUI_USER};" 2>/dev/null || true
fi
