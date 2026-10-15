#!/usr/bin/env bash
# Habilita el Data API sobre la base del branch production.
# OJO: en la CLI v1.21.0 estos comandos están OCULTOS y marcados como "Private Preview".
# Si fallan (por ejemplo, porque tu workspace no tiene la preview), el script NO rompe el
# pipeline: deja una advertencia para habilitarlo desde la UI (Lakebase App > Data API > Enable).
source "$(dirname "$0")/comun.sh"

db_name="$(db_resource_name)"
if [[ -z "${db_name}" ]]; then
  echo "::error::No se encontró el recurso de la base ${PG_DATABASE} en ${BRANCH_PATH}"; exit 1
fi
api_name="${db_name}/data-api"
log "Base: ${db_name}"

if databricks postgres get-data-api "${api_name}" -o json >/dev/null 2>&1; then
  log "El Data API ya está habilitado"
elif databricks postgres create-data-api "${db_name}" -o json; then
  log "Data API habilitado vía CLI"
else
  echo "::warning::No se pudo habilitar el Data API por CLI (comando en Private Preview). Habilítalo manualmente: Lakebase App > proyecto ${PROJECT_ID} > Data API > Enable Data API. Luego vuelve a ejecutar el workflow con 'solo_smoke_test'."
fi
