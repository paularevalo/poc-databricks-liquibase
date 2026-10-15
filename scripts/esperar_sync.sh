#!/usr/bin/env bash
# Espera a que las synced tables (modo SNAPSHOT) terminen la carga inicial en Lakebase.
# Criterio: las tablas existen en Postgres y tienen filas.
source "$(dirname "$0")/comun.sh"

TIMEOUT_SEG="${TIMEOUT_SEG:-2700}"   # 45 min
INTERVALO=60
transcurrido=0

log "Esperando carga de synced tables en ${PG_SCHEMA} (timeout ${TIMEOUT_SEG}s)"
while (( transcurrido < TIMEOUT_SEG )); do
  conteo=$(lb_psql -t -A -c "
    SELECT COALESCE((SELECT count(*) FROM ${PG_SCHEMA}.atenciones), 0)
         || '/' ||
           COALESCE((SELECT count(*) FROM ${PG_SCHEMA}.pacientes), 0);" 2>/dev/null || echo "pendiente")
  echo "  atenciones/pacientes = ${conteo}"
  if [[ "${conteo}" =~ ^[1-9][0-9]*/[1-9][0-9]*$ ]]; then
    log "Synced tables cargadas: ${conteo}"
    exit 0
  fi
  sleep "${INTERVALO}"; transcurrido=$(( transcurrido + INTERVALO ))
done

echo "::error::Las synced tables no terminaron de cargar en ${TIMEOUT_SEG}s. Revisa el estado del pipeline en el workspace."
exit 1
