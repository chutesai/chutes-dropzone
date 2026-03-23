#!/usr/bin/env sh
set -eu

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres <<-EOSQL
  SELECT 'CREATE DATABASE ${POSTGRES_N8N_DB:-${POSTGRES_DB:-n8n}}'
  WHERE NOT EXISTS (
    SELECT FROM pg_database WHERE datname = '${POSTGRES_N8N_DB:-${POSTGRES_DB:-n8n}}'
  )\gexec

  SELECT 'CREATE DATABASE ${POSTGRES_OPENWEBUI_DB:-openwebui}'
  WHERE NOT EXISTS (
    SELECT FROM pg_database WHERE datname = '${POSTGRES_OPENWEBUI_DB:-openwebui}'
  )\gexec
EOSQL
