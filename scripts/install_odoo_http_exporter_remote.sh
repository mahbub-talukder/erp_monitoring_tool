#!/usr/bin/env bash
set -euo pipefail

# Install Odoo HTTP req/s collector on CCDL Live and Backup (werkzeug Docker logs → node_exporter textfile).
#
# Prerequisites:
#   - node_exporter on :9100
#   - Docker Odoo containers running (odoo_server1 / odoo_server2)
#   - ccdlerp user can run docker (or collector runs as root via systemd)
#
# Usage:
#   ./scripts/install_odoo_http_exporter_remote.sh              # dry-run
#   DRY_RUN=false ./scripts/install_odoo_http_exporter_remote.sh

DRY_RUN="${DRY_RUN:-true}"
NODE_EXPORTER_USER="${NODE_EXPORTER_USER:-node_exporter}"
SSH_TIMEOUT="${SSH_TIMEOUT:-20}"

# Format: "ip|ssh_port|username|password|odoo_containers(space-separated)"
HOSTS=(
  "10.10.21.5|9841|ccdlerp|CCDL@ERP0pen|odoo_server1"    # CCDL-Live Server 1
  "10.10.21.6|9841|ccdlerp|CCDL@ERP0pen|odoo_server2"    # CCDL Backup Server
)

if ! command -v sshpass >/dev/null 2>&1; then
  echo "sshpass is required. Install: sudo apt-get install -y sshpass" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COLLECTOR_SRC="${SCRIPT_DIR}/odoo_http_log_collector.sh"

if [[ ! -f "$COLLECTOR_SRC" ]]; then
  echo "Missing collector script: ${COLLECTOR_SRC}" >&2
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

copy_collector() {
  local password="$1"
  local port="$2"
  local user="$3"
  local ip="$4"
  sshpass -p "$password" scp \
    -o StrictHostKeyChecking=no \
    -o ConnectTimeout="$SSH_TIMEOUT" \
    -P "$port" \
    "$COLLECTOR_SRC" "${user}@${ip}:/tmp/odoo_http_log_collector.sh"
}

REMOTE_SCRIPT=$(cat <<'EOF'
set -euo pipefail
NE_USER="__NODE_EXPORTER_USER__"
ODOO_CONTAINERS="__ODOO_CONTAINERS__"
SUDO_PASSWORD="__SUDO_PASSWORD__"

run_sudo() {
  # shellcheck disable=SC2059
  printf '%s\n' "$SUDO_PASSWORD" | sudo -S -p '' "$@"
}

run_sudo install -m 0755 /tmp/odoo_http_log_collector.sh /usr/local/bin/odoo_http_log_collector.sh
run_sudo mkdir -p /var/lib/node_exporter/textfile /var/lib/node_exporter/odoo_http
run_sudo chown -R "${NE_USER}:${NE_USER}" /var/lib/node_exporter/textfile /var/lib/node_exporter/odoo_http

# Enable node_exporter textfile collector (patch existing unit if needed).
if [[ -f /etc/systemd/system/node_exporter.service ]]; then
  if ! grep -q 'collector.textfile.directory' /etc/systemd/system/node_exporter.service; then
    run_sudo sed -i \
      's|--collector.systemd|--collector.systemd --collector.textfile.directory=/var/lib/node_exporter/textfile|' \
      /etc/systemd/system/node_exporter.service
    run_sudo systemctl daemon-reload
    run_sudo systemctl restart node_exporter
  fi
fi

sudo -S -p '' bash -c "cat > /etc/systemd/system/odoo_http_collector.service <<UNIT
[Unit]
Description=Odoo HTTP log collector for Prometheus
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Environment=ODOO_CONTAINERS=${ODOO_CONTAINERS}
Environment=NODE_EXPORTER_USER=${NE_USER}
ExecStart=/usr/local/bin/odoo_http_log_collector.sh
UNIT" <<<"$SUDO_PASSWORD"

sudo -S -p '' bash -c "cat > /etc/systemd/system/odoo_http_collector.timer <<UNIT
[Unit]
Description=Run Odoo HTTP log collector every 30s

[Timer]
OnBootSec=1min
OnUnitActiveSec=30s
AccuracySec=1s

[Install]
WantedBy=timers.target
UNIT" <<<"$SUDO_PASSWORD"

run_sudo systemctl daemon-reload
run_sudo systemctl enable --now odoo_http_collector.timer
run_sudo systemctl start odoo_http_collector.service

sleep 2
run_sudo cat /var/lib/node_exporter/textfile/odoo_http.prom
echo "---"
curl -fsS http://127.0.0.1:9100/metrics | grep '^odoo_http_requests_total' || true
echo "odoo_http_collector installed (containers=${ODOO_CONTAINERS})"
EOF
)

for host in "${HOSTS[@]}"; do
  IFS='|' read -r ip port username password containers <<<"$host"
  echo "----"
  echo "Target: ${ip}:${port} (${username}) containers=${containers}"
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[DRY-RUN] Would install odoo_http_log_collector on ${ip}"
    continue
  fi

  copy_collector "$password" "$port" "$username" "$ip"

  SCRIPT="${REMOTE_SCRIPT/__NODE_EXPORTER_USER__/$NODE_EXPORTER_USER}"
  SCRIPT="${SCRIPT/__ODOO_CONTAINERS__/$containers}"
  SCRIPT="${SCRIPT/__SUDO_PASSWORD__/$password}"

  run_remote "$password" "$port" "$username" "$ip" "$SCRIPT"
done

echo "----"
echo "Completed odoo_http_collector rollout."
echo "Grafana panel reads: sum(rate(odoo_http_requests_total{job=\"node\", server=~\"live|backup\"}[5m]))"
