#!/usr/bin/env bash
# Prueba funcional mínima del Data API (NO es prueba de estrés): unas pocas consultas
# de lectura con la identidad CONSUMIDORA (distinta del owner del proyecto).
#
# Token del consumidor, en orden de preferencia:
#   1) DATA_API_CLIENT_ID + DATA_API_CLIENT_SECRET  → OAuth M2M de un service principal
#   2) DATA_API_TOKEN                               → token OAuth ya emitido (p. ej. de tu usuario)
# URL: DATA_API_URL, o se intenta leer de `databricks postgres get-data-api`.
source "$(dirname "$0")/comun.sh"

# --- URL del Data API ---
if [[ -z "${DATA_API_URL:-}" ]]; then
  db_name="$(db_resource_name)"
  DATA_API_URL="$(databricks postgres get-data-api "${db_name}/data-api" -o json 2>/dev/null \
                  | jq -r '[.. | strings | select(startswith("https://"))][0] // empty')"
fi
if [[ -z "${DATA_API_URL:-}" ]]; then
  echo "::warning::No se pudo obtener la URL del Data API. Cópiala de Lakebase App > Data API > API URL y guárdala como variable DATA_API_URL del repositorio."
  exit 0
fi
DATA_API_URL="${DATA_API_URL%/}"
log "Data API: ${DATA_API_URL}"

# --- Token del consumidor ---
if [[ -n "${DATA_API_CLIENT_ID:-}" && -n "${DATA_API_CLIENT_SECRET:-}" ]]; then
  TOKEN="$(curl -fsS -u "${DATA_API_CLIENT_ID}:${DATA_API_CLIENT_SECRET}" \
            -d 'grant_type=client_credentials&scope=all-apis' \
            "${DATABRICKS_HOST%/}/oidc/v1/token" | jq -r .access_token)"
elif [[ -n "${DATA_API_TOKEN:-}" ]]; then
  TOKEN="${DATA_API_TOKEN}"
else
  echo "::warning::Sin credenciales del consumidor (DATA_API_CLIENT_ID/SECRET o DATA_API_TOKEN). Se omite el smoke test."
  exit 0
fi

fallos=0
probar() {  # probar <descripcion> <ruta+query>
  local desc="$1" ruta="$2" salida codigo ms
  salida="$(mktemp)"
  read -r codigo ms < <(curl -sS -o "${salida}" -w '%{http_code} %{time_total}\n' \
      -H "Authorization: Bearer ${TOKEN}" -H "Prefer: count=exact" \
      "${DATA_API_URL}${ruta}")
  if [[ "${codigo}" == "200" ]]; then
    printf '  OK   %-40s %4s ms  filas=%s\n' "${desc}" "$(awk "BEGIN{printf \"%d\", ${ms}*1000}")" "$(jq 'length' "${salida}")"
  else
    printf '  FAIL %-40s HTTP %s\n' "${desc}" "${codigo}"; head -c 400 "${salida}"; echo
    fallos=$((fallos + 1))
  fi
}

log "Consultas de lectura"
probar "lookup por PK"              "/public/atenciones?atencion_id=eq.1"
probar "historial de un paciente"   "/public/atenciones?paciente_id=eq.PAC-0000001&order=fecha_atencion.desc&limit=20&select=atencion_id,fecha_atencion,servicio,diagnostico_codigo"
probar "filtro por servicio"        "/public/atenciones?servicio=eq.Emergencia&limit=10&select=atencion_id,paciente_id"
probar "ficha de paciente"          "/public/pacientes?paciente_id=eq.PAC-0000001"

log "Escritura (debe FALLAR: el consumidor es solo lectura)"
codigo=$(curl -sS -o /dev/null -w '%{http_code}' -X PATCH \
  -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" \
  -d '{"estado":"x"}' "${DATA_API_URL}/public/atenciones?atencion_id=eq.1")
if [[ "${codigo}" =~ ^(401|403|405)$ ]]; then echo "  OK   escritura rechazada (HTTP ${codigo})"
else echo "  FAIL la escritura devolvió HTTP ${codigo}"; fallos=$((fallos + 1)); fi

(( fallos == 0 )) || { echo "::error::${fallos} verificaciones fallaron"; exit 1; }
log "Smoke test OK"
