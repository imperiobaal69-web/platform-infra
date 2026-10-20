#!/usr/bin/env bash
# Writes random credentials for the local overlay into
# k8s/overlays/local/secrets/*.env (gitignored). Existing files are kept, so
# re-running does not rotate passwords under a running Postgres.
set -euo pipefail
cd "$(dirname "$0")/.."
dir=k8s/overlays/local/secrets
mkdir -p "$dir"
umask 077

if [[ -f $dir/postgres.env && -f $dir/app.env && -f $dir/exporter.env ]]; then
  echo "local secrets already present in $dir"
  exit 0
fi

rand() { openssl rand -hex 24; }
superuser=$(rand)
app=$(rand)
exporter=$(rand)
host=postgres.audio-jobs-data.svc.cluster.local

cat >"$dir/postgres.env" <<EOF
POSTGRES_PASSWORD=$superuser
APP_PASSWORD=$app
EXPORTER_PASSWORD=$exporter
EOF
cat >"$dir/app.env" <<EOF
DATABASE_URL=postgres://audiojobs:$app@$host:5432/audiojobs?sslmode=disable
EOF
cat >"$dir/exporter.env" <<EOF
DATA_SOURCE_NAME=postgresql://exporter:$exporter@$host:5432/audiojobs?sslmode=disable
EOF
echo "wrote $dir/{postgres,app,exporter}.env"
