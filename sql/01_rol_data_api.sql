-- Configura el acceso de SOLO LECTURA para el consumidor del Data API.
-- Se ejecuta con `databricks psql` como la identidad que desplegó el proyecto (owner).
--
-- Variables psql (se pasan con -v):
--   consumidor       identidad Databricks que consumirá el Data API:
--                    email de usuario o application ID (UUID) de service principal.
--                    NO puede ser el owner del proyecto.
--   tipo_consumidor  USER | SERVICE_PRINCIPAL
--   pg_schema        esquema Postgres donde quedaron las synced tables
--                    (por defecto, el mismo nombre del esquema UC de origen)

\set ON_ERROR_STOP on

CREATE EXTENSION IF NOT EXISTS databricks_auth;

-- Crea el rol Postgres ligado a la identidad Databricks (idempotente)
SELECT CASE
  WHEN EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'consumidor')
    THEN 'rol ya existe: ' || :'consumidor'
  ELSE (SELECT 'rol creado: ' || :'consumidor'
        FROM (SELECT databricks_create_role(:'consumidor', :'tipo_consumidor')) AS t)
END AS resultado;

-- El rol 'authenticator' del Data API debe poder asumir la identidad del consumidor
GRANT :"consumidor" TO authenticator;

-- Solo lectura sobre el esquema de las synced tables
GRANT USAGE ON SCHEMA :"pg_schema" TO :"consumidor";
GRANT SELECT ON ALL TABLES IN SCHEMA :"pg_schema" TO :"consumidor";
ALTER DEFAULT PRIVILEGES IN SCHEMA :"pg_schema" GRANT SELECT ON TABLES TO :"consumidor";

-- El Data API expone por defecto solo el esquema 'public'. En lugar de cambiar esa
-- configuración, publicamos vistas en 'public' con security_invoker = true, para que
-- los permisos (y cualquier RLS futura) se evalúen con la identidad que consulta.
CREATE OR REPLACE VIEW public.atenciones WITH (security_invoker = true) AS
  SELECT * FROM :"pg_schema".atenciones;
CREATE OR REPLACE VIEW public.pacientes WITH (security_invoker = true) AS
  SELECT * FROM :"pg_schema".pacientes;
GRANT USAGE ON SCHEMA public TO :"consumidor";
GRANT SELECT ON public.atenciones, public.pacientes TO :"consumidor";

-- Pide al Data API recargar su caché de esquema (mecanismo estándar de PostgREST).
-- VERIFICADO: Lakebase NO lo atiende. Tras crear las vistas hay que pulsar
-- "Refresh schema cache" en Lakebase App > Data API. Se deja por si cambia en el futuro.
NOTIFY pgrst, 'reload schema';

-- Verificación
SELECT table_schema, table_name, privilege_type
FROM information_schema.role_table_grants
WHERE grantee = :'consumidor'
ORDER BY table_name;
