#!/bin/sh
# Runs once, when the data directory is first initialised. Creates the
# application owner role and a read-only monitoring role. Passwords come from
# the postgres Secret.
set -eu
psql -v ON_ERROR_STOP=1 --username postgres --dbname "$POSTGRES_DB" \
  -v app_password="$APP_PASSWORD" -v exporter_password="$EXPORTER_PASSWORD" <<'EOSQL'
CREATE ROLE audiojobs LOGIN PASSWORD :'app_password';
ALTER DATABASE audiojobs OWNER TO audiojobs;
CREATE ROLE exporter LOGIN PASSWORD :'exporter_password';
GRANT pg_monitor TO exporter;
ALTER DEFAULT PRIVILEGES FOR ROLE audiojobs IN SCHEMA public GRANT SELECT ON TABLES TO exporter;
EOSQL
