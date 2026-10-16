#!/usr/bin/env bash
# Funciones y variables compartidas por los scripts del sandbox.
set -euo pipefail

: "${PROJECT_ID:=hcl-sandbox}"
: "${BRANCH_ID:=production}"
: "${ENDPOINT_ID:=primary}"          # endpoint por defecto que Lakebase crea en el branch production
: "${PG_DATABASE:=databricks_postgres}"
: "${UC_SCHEMA:=hcl_sintetico}"
: "${SERVING_SCHEMA:=hcl_serving}"
: "${PG_SCHEMA:=${SERVING_SCHEMA}}"  # synced_table_id = catalog.<schema>.<tabla> → tabla <tabla> en el esquema Postgres <schema>

BRANCH_PATH="projects/${PROJECT_ID}/branches/${BRANCH_ID}"
ENDPOINT_PATH="${BRANCH_PATH}/endpoints/${ENDPOINT_ID}"

log() { printf '\n\033[1;34m[%s] %s\033[0m\n' "$(date -u +%H:%M:%S)" "$*"; }

# Ejecuta SQL contra Lakebase con la identidad del pipeline (databricks psql gestiona el token OAuth)
lb_psql() {
  databricks psql "${ENDPOINT_PATH}" --max-retries 5 -- \
    -d "${PG_DATABASE}" -v ON_ERROR_STOP=1 -X -q "$@"
}

# Resource name del recurso database (necesario para el Data API)
db_resource_name() {
  databricks postgres list-databases "${BRANCH_PATH}" -o json \
    | jq -r --arg db "${PG_DATABASE}" '
        (if type=="array" then .[] else (.databases // [])[] end)
        | select((.status.postgres_database // .spec.postgres_database // .postgres_database) == $db)
        | .name' | head -n1
}
