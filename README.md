# Sandbox Lakebase + Data API (historias clínicas sintéticas)

Ecosistema efímero para **validar la arquitectura** (no para pruebas de estrés):
crear → cargar datos sintéticos → exponer en solo lectura por el Data API → verificar → destruir.
Todo se maneja con la **Databricks CLI** desde **GitHub Actions**, usando *Declarative Automation
Bundles* (antes "Databricks Asset Bundles") como IaC. El estado del despliegue vive en el propio
workspace, así que **no necesitas un backend de Terraform** (S3, etc.).

```
GitHub Actions ──CLI──▶ Bundle infra ──▶ Proyecto Lakebase (branch production / endpoint primary)
                                    ├──▶ Esquema UC  <catalog>.hcl_sintetico
                                    └──▶ Job serverless → Delta: pacientes, atenciones, catalogo_diagnosticos
                ──CLI──▶ Bundle sync  ──▶ Synced tables (SNAPSHOT) Delta → Postgres
                ──psql─▶ Rol de solo lectura + vistas en public (security_invoker)
                ──curl─▶ Data API (PostgREST) → smoke test
```

## Estructura

| Ruta | Qué hace |
|---|---|
| `bundles/infra/databricks.yml` | Proyecto Lakebase (`purge_on_delete: true`), esquema UC y job generador |
| `bundles/infra/src/generar_datos_clinicos.py` | Generador PySpark nativo (sin librerías externas) |
| `bundles/sync/databricks.yml` | Synced tables `atenciones` y `pacientes` |
| `sql/01_rol_data_api.sql` | Rol del consumidor, `GRANT SELECT`, vistas en `public` |
| `scripts/*.sh` | Espera de la sincronización, habilitación del Data API, smoke test |
| `.github/workflows/deploy.yml` | Despliegue completo (manual, `workflow_dispatch`) |
| `.github/workflows/destroy.yml` | Destrucción + verificación de que no quedó nada |

## Configuración en GitHub

**Secrets** (Settings → Secrets and variables → Actions):

| Secret | Uso |
|---|---|
| `DATABRICKS_HOST` | URL del workspace, p. ej. `https://dbc-xxxx.cloud.databricks.com` |
| `DATABRICKS_CLIENT_ID` + `DATABRICKS_CLIENT_SECRET` | OAuth M2M de un service principal (**preferido**) |
| `DATABRICKS_TOKEN` | Alternativa: personal access token (deja vacíos los dos anteriores) |
| `DATA_API_CLIENT_ID` + `DATA_API_CLIENT_SECRET` | Credenciales del **consumidor** del Data API (opcional) |
| `DATA_API_TOKEN` | Alternativa: token OAuth del consumidor (opcional) |

**Variables** (opcionales): `PROJECT_ID` (`hcl-sandbox`), `UC_CATALOG` (`workspace`), `UC_SCHEMA`
(`hcl_sintetico`), `DATA_API_CONSUMIDOR` (email o application ID), `DATA_API_TIPO_CONSUMIDOR`
(`USER` o `SERVICE_PRINCIPAL`), `DATA_API_URL` (si la CLI no logra obtenerla).

Crea también un **environment** `sandbox` (Settings → Environments) y, si quieres, actívale
*required reviewers* para aprobar cada despliegue o destrucción.

> **Regla del Data API:** el consumidor **no puede ser el owner** del proyecto (la identidad que
> despliega). Si despliegas con un service principal, puedes usar **tu usuario** como consumidor
> (`DATA_API_CONSUMIDOR=tu@email`, `TIPO=USER`) y pasar un token tuyo en `DATA_API_TOKEN`.

## Uso

1. **Actions → "Sandbox Lakebase - desplegar" → Run workflow.** Con los valores por defecto genera
   10.000 pacientes y ~100.000 atenciones con notas de ~2 KB (~200 MB en Delta).
2. Revisa el resumen y el log del paso *Smoke test*: 4 consultas de lectura deben dar `OK` y la
   escritura debe ser **rechazada**.
3. **Actions → "Sandbox Lakebase - destruir"**, escribiendo `DESTRUIR`. El workflow falla si el
   proyecto sigue existiendo, incluso en soft-delete.

> **Paso manual obligatorio (verificado):** después de crear o cambiar vistas/tablas, pulsa
> **Lakebase App → Data API → Refresh schema cache**. El `NOTIFY pgrst, 'reload schema'` del script SQL
> **no** recarga la caché del Data API de Lakebase; sin el refresh, el API responde `404 PGRST205`.

Para repetir solo la verificación (por ejemplo, después de habilitar el Data API a mano), ejecuta el
despliegue con `solo_smoke_test = true`.

## Qué está verificado y qué no

**Verificado** contra documentación oficial y contra el código fuente de la CLI v1.21.0:
- Los dos `databricks.yml` validan **sin errores** contra el JSON schema oficial de bundles
  (con un control negativo: un campo inventado sí es detectado).
- Recursos `postgres_projects` (incluido `purge_on_delete`), `postgres_synced_tables` (modo
  `SNAPSHOT`), `schemas` y `jobs` serverless (`environment_version`).
- Comandos y flags de la CLI usados: `bundle deploy/run/destroy --auto-approve --var`,
  `bundle deployment unbind`, `psql`, `postgres list-databases`, `postgres list-projects --show-deleted`,
  `postgres delete-project --purge`, `schemas delete --force`.
- Límites de Free Edition: 1 proyecto Lakebase con scale-to-zero, solo serverless, 5 tareas de job
  concurrentes, una pipeline activa por tipo, acceso saliente a internet restringido.

**No verificado / supuestos** (pueden requerir ajuste en tu primer despliegue):
- ~~El generador PySpark no se ejecutó~~ **Validado** en Free Edition: generó los datos, se sincronizaron a
  Lakebase y se consultaron por el Data API.
- **Data API por CLI**: `postgres create-data-api` existe, pero está **oculto y marcado como Private
  Preview**. Si falla, el workflow deja un aviso y lo habilitas desde la UI (Lakebase App → Data API).
- **Free Edition y automatización**: la documentación indica que el login de usuarios es solo por OTP,
  Google o Microsoft. **No confirmé** que puedas crear service principals ni personal access tokens en
  Free Edition. Si no puedes, el paso de autenticación desde GitHub será el bloqueante; los bundles
  funcionan igual desde tu máquina con `databricks auth login`.
- **Destino de las synced tables**: `workspace.hcl_serving.<tabla>` en UC, que en Postgres queda como
  `hcl_serving.<tabla>` (así lo define `synced_table_id`). Cambia el esquema con la variable `SERVING_SCHEMA`.
- **Dos synced tables** en Free Edition (*una pipeline activa por tipo*): si la segunda falla por ese
  límite, vuelve a ejecutar el despliegue o comenta `pacientes` en `bundles/sync/databricks.yml`.
- **Catálogo por defecto** `workspace`: es un supuesto. Cámbialo con la variable `UC_CATALOG` si tu
  workspace usa otro.
- `environment_version: "3"` del job serverless: ajústalo si tu workspace ofrece otra versión.

## Notas

- **Uso no comercial**: Free Edition no admite uso comercial. Usa este sandbox para aprender y validar
  el diseño con datos ficticios; la PoC formal (costos, 700 TPS) debe correr en la cuenta corporativa.
- Los datos son **100% sintéticos**: nombres combinados al azar, identificadores ficticios
  (`PAC-0000001`) y un subconjunto de códigos CIE-10 públicos. Las tablas llevan la propiedad
  `synthetic = true`.
- El tamaño por registro se controla con `nota_bytes`; con ~100.000 bytes reproduces el perfil de
  "6 TB / 60M registros" (en la cuenta corporativa, no en Free Edition).
