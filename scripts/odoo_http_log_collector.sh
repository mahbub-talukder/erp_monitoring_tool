#!/usr/bin/env bash
# Count Odoo werkzeug HTTP lines from Docker logs; expose via node_exporter textfile.
# Installed on app servers by install_odoo_http_exporter_remote.sh.
set -euo pipefail

TEXTFILE_DIR="${TEXTFILE_DIR:-/var/lib/node_exporter/textfile}"
STATE_DIR="${STATE_DIR:-/var/lib/node_exporter/odoo_http}"
NODE_EXPORTER_USER="${NODE_EXPORTER_USER:-node_exporter}"
CONTAINERS="${ODOO_CONTAINERS:-odoo_server1}"

mkdir -p "$TEXTFILE_DIR" "$STATE_DIR"

count_container() {
  local container="$1"
  local since_file="${STATE_DIR}/${container}.since"
  local total_file="${STATE_DIR}/${container}.total"

  if ! docker ps --format '{{.Names}}' | grep -qx "$container"; then
    echo "odoo_http_collector: container ${container} not running, skipping" >&2
    return 0
  fi

  local since
  if [[ -f "$since_file" ]]; then
    since="$(<"$since_file")"
  else
    since="$(date -u -d '60 seconds ago' +%Y-%m-%dT%H:%M:%SZ)"
  fi

  local count
  count="$(
    docker logs "$container" --since "$since" 2>&1 \
      | awk '/ werkzeug: / && $0 !~ /\/web\/health|\/longpolling|\/websocket/ { n++ } END { print n + 0 }'
  )"

  local total=0
  [[ -f "$total_file" ]] && total="$(<"$total_file")"
  total=$((total + count))

  date -u +%Y-%m-%dT%H:%M:%SZ >"$since_file"
  echo "$total" >"$total_file"

  printf 'odoo_http_requests_total{container="%s"} %s\n' "$container" "$total"
}

TMP="${TEXTFILE_DIR}/odoo_http.prom.$$"
{
  echo '# HELP odoo_http_requests_total Odoo HTTP requests from werkzeug access log (excludes health/longpolling/websocket)'
  echo '# TYPE odoo_http_requests_total counter'
  for container in $CONTAINERS; do
    count_container "$container"
  done
} >"$TMP"

mv "$TMP" "${TEXTFILE_DIR}/odoo_http.prom"
chown "${NODE_EXPORTER_USER}:${NODE_EXPORTER_USER}" "${TEXTFILE_DIR}/odoo_http.prom"
chmod 0644 "${TEXTFILE_DIR}/odoo_http.prom"
