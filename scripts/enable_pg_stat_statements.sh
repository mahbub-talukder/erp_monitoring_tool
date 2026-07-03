#!/usr/bin/env bash
set -euo pipefail

# Enable pg_stat_statements on CCDL Live and Backup Postgres (port 5000).

DRY_RUN="${DRY_RUN:-true}"
SSH_TIMEOUT="${SSH_TIMEOUT:-20}"
PG_PORT="${PG_PORT:-5000}"
PG_USER="${PG_USER:-odoo}"
PG_PASSWORD="${PG_PASSWORD:-123456}"
PG_DATABASE="${PG_DATABASE:-postgres}"

# Format: "name|ip|ssh_port|ssh_user|ssh_password"
HOSTS=(
  "live|10.10.21.5|9841|ccdlerp|CCDL@ERP0pen"
  "backup|10.10.21.6|9841|ccdlerp|CCDL@ERP0pen"
)

if ! command -v sshpass >/dev/null 2>&1; then
  echo "sshpass is required. Install: sudo apt-get install -y sshpass" >&2
  exit 1
fi

run_remote() {
  local password="$1"
  local port="$2"
  local user="$3"
  local ip="$4"
  local cmd="$5"
  sshpass -p "$password" ssh \
    -o StrictHostKeyChecking=no \
    -o ConnectTimeout="$SSH_TIMEOUT" \
    -p "$port" "$user@$ip" "$cmd"
}

REMOTE_SCRIPT=$(cat <<'EOF'
set -euo pipefail
PG_PORT="__PG_PORT__"
PG_USER="__PG_USER__"
PG_PASSWORD="__PG_PASSWORD__"
PG_DATABASE="__PG_DATABASE__"
TARGET_NAME="__TARGET_NAME__"
SUDO_PASSWORD="__SUDO_PASSWORD__"

echo "Checking shared_preload_libraries on ${TARGET_NAME}..."
if command -v psql >/dev/null 2>&1; then
  export PGPASSWORD="${PG_PASSWORD}"
  PRELOAD="$(psql -h 127.0.0.1 -p "${PG_PORT}" -U "${PG_USER}" -d "${PG_DATABASE}" -tAc "SHOW shared_preload_libraries;" 2>/dev/null || true)"
  if [[ "${PRELOAD}" != *pg_stat_statements* ]]; then
    echo "WARNING: pg_stat_statements is not in shared_preload_libraries."
    echo "  Current value: ${PRELOAD:-<empty>}"
    echo "  Add pg_stat_statements to postgresql.conf, restart Postgres, then re-run this script."
  else
    echo "OK: pg_stat_statements is in shared_preload_libraries."
  fi
  echo "Running: CREATE EXTENSION IF NOT EXISTS pg_stat_statements;"
  psql -h 127.0.0.1 -p "${PG_PORT}" -U "${PG_USER}" -d "${PG_DATABASE}" -c "CREATE EXTENSION IF NOT EXISTS pg_stat_statements;"
  echo "Done on ${TARGET_NAME}."
else
  echo "psql not found on remote host; trying sudo -u postgres..."
  printf '%s\n' "${SUDO_PASSWORD}" | sudo -S -p '' psql -p "${PG_PORT}" -d "${PG_DATABASE}" -c "CREATE EXTENSION IF NOT EXISTS pg_stat_statements;"
  echo "Done on ${TARGET_NAME}."
fi
EOF
)

for host in "${HOSTS[@]}"; do
  IFS='|' read -r name ip port username password <<<"$host"
  echo "----"
  echo "Target: ${name} (${ip}:${port})"

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[DRY-RUN] Would enable pg_stat_statements on ${name} (${ip})"
    continue
  fi

  SCRIPT="${REMOTE_SCRIPT/__PG_PORT__/$PG_PORT}"
  SCRIPT="${SCRIPT/__PG_USER__/$PG_USER}"
  SCRIPT="${SCRIPT/__PG_PASSWORD__/$PG_PASSWORD}"
  SCRIPT="${SCRIPT/__PG_DATABASE__/$PG_DATABASE}"
  SCRIPT="${SCRIPT/__TARGET_NAME__/$name}"
  SCRIPT="${SCRIPT/__SUDO_PASSWORD__/$password}"

  run_remote "$password" "$port" "$username" "$ip" "$SCRIPT"
done

echo "----"
echo "Completed pg_stat_statements setup."
