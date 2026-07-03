#!/usr/bin/env bash
set -euo pipefail

# Install nginx-prometheus-exporter on CCDL Live and Backup servers (systemd, :9113).
#
# Prerequisites on each target host:
#   1. nginx stub_status enabled (host nginx or Docker nginx published to localhost)
#   2. Default scrape URI: http://127.0.0.1/stub_status
#      Override per host in HOSTS[] or set NGINX_SCRAPE_URI for all hosts.
#
# Usage:
#   ./scripts/install_nginx_exporter_remote.sh              # dry-run
#   DRY_RUN=false ./scripts/install_nginx_exporter_remote.sh

DRY_RUN="${DRY_RUN:-true}"
NGINX_EXPORTER_VERSION="${NGINX_EXPORTER_VERSION:-1.4.2}"
NGINX_EXPORTER_USER="${NGINX_EXPORTER_USER:-nginx_exporter}"
NGINX_LISTEN_PORT="${NGINX_LISTEN_PORT:-9113}"
NGINX_SCRAPE_URI="${NGINX_SCRAPE_URI:-http://127.0.0.1/stub_status}"
SSH_TIMEOUT="${SSH_TIMEOUT:-20}"

# Format: "ip|ssh_port|username|password|nginx_scrape_uri(optional)"
HOSTS=(
  "10.10.21.5|9841|ccdlerp|CCDL@ERP0pen|http://127.0.0.1/stub_status"   # CCDL-Live Server 1
  "10.10.21.6|9841|ccdlerp|CCDL@ERP0pen|http://127.0.0.1/stub_status"   # CCDL Backup Server
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
VERSION="__NGINX_EXPORTER_VERSION__"
NE_USER="__NGINX_EXPORTER_USER__"
LISTEN_PORT="__NGINX_LISTEN_PORT__"
SCRAPE_URI="__NGINX_SCRAPE_URI__"
SUDO_PASSWORD="__SUDO_PASSWORD__"

run_sudo() {
  # shellcheck disable=SC2059
  printf '%s\n' "$SUDO_PASSWORD" | sudo -S -p '' "$@"
}

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|amd64) GOARCH="amd64" ;;
  aarch64|arm64) GOARCH="arm64" ;;
  *) echo "Unsupported arch: $ARCH" >&2; exit 1 ;;
esac

TAR="nginx-prometheus-exporter_${VERSION}_linux_${GOARCH}.tar.gz"
URL="https://github.com/nginx/nginx-prometheus-exporter/releases/download/v${VERSION}/${TAR}"
TMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

echo "Checking nginx stub_status at ${SCRAPE_URI} ..."
if ! curl -fsS --max-time 5 "${SCRAPE_URI}" >/dev/null 2>&1; then
  echo "WARNING: stub_status not reachable at ${SCRAPE_URI}" >&2
  echo "  Add stub_status to nginx before relying on Odoo HTTP req/s metrics." >&2
  echo "  Example nginx snippet:" >&2
  echo "    location /stub_status {" >&2
  echo "      stub_status;" >&2
  echo "      allow 127.0.0.1;" >&2
  echo "      deny all;" >&2
  echo "    }" >&2
  echo "  For Docker nginx, publish stub_status to the host or set a custom URI in HOSTS[]." >&2
  echo "  Continuing install anyway (exporter will retry stub_status in the background)." >&2
fi

if ! id -u "$NE_USER" >/dev/null 2>&1; then
  run_sudo useradd --no-create-home --shell /usr/sbin/nologin "$NE_USER"
fi

curl -fsSL "$URL" -o "$TMP_DIR/$TAR"
tar -xzf "$TMP_DIR/$TAR" -C "$TMP_DIR"

BIN_SRC="$TMP_DIR/nginx-prometheus-exporter"
if [[ ! -f "$BIN_SRC" ]]; then
  echo "Binary not found in archive (expected ${BIN_SRC})" >&2
  ls -la "$TMP_DIR" >&2
  exit 1
fi
run_sudo install -m 0755 "$BIN_SRC" /usr/local/bin/nginx-prometheus-exporter
run_sudo chown root:root /usr/local/bin/nginx-prometheus-exporter

sudo -S -p '' bash -c "cat > /etc/systemd/system/nginx_exporter.service <<UNIT
[Unit]
Description=Prometheus Nginx Exporter
After=network-online.target docker.service
Wants=network-online.target

[Service]
User=${NE_USER}
Group=${NE_USER}
Type=simple
ExecStart=/usr/local/bin/nginx-prometheus-exporter \\
  -nginx.scrape-uri=${SCRAPE_URI} \\
  -web.listen-address=:${LISTEN_PORT}
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
UNIT" <<<"$SUDO_PASSWORD"

run_sudo systemctl daemon-reload
run_sudo systemctl enable --now nginx_exporter
run_sudo systemctl is-active --quiet nginx_exporter
curl -fsS "http://127.0.0.1:${LISTEN_PORT}/metrics" | head -n 5
echo "nginx_exporter installed and listening on :${LISTEN_PORT} (scrape-uri=${SCRAPE_URI})"
EOF
)

for host in "${HOSTS[@]}"; do
  IFS='|' read -r ip port username password scrape_uri <<<"$host"
  scrape_uri="${scrape_uri:-$NGINX_SCRAPE_URI}"
  echo "----"
  echo "Target: ${ip}:${port} (${username}) scrape-uri=${scrape_uri}"
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[DRY-RUN] Would install nginx-prometheus-exporter v${NGINX_EXPORTER_VERSION} on :${NGINX_LISTEN_PORT} at ${ip}"
    continue
  fi

  SCRIPT="${REMOTE_SCRIPT/__NGINX_EXPORTER_VERSION__/$NGINX_EXPORTER_VERSION}"
  SCRIPT="${SCRIPT/__NGINX_EXPORTER_USER__/$NGINX_EXPORTER_USER}"
  SCRIPT="${SCRIPT/__NGINX_LISTEN_PORT__/$NGINX_LISTEN_PORT}"
  SCRIPT="${SCRIPT/__NGINX_SCRAPE_URI__/$scrape_uri}"
  SCRIPT="${SCRIPT/__SUDO_PASSWORD__/$password}"

  run_remote "$password" "$port" "$username" "$ip" "$SCRIPT"
done

echo "----"
echo "Completed nginx_exporter rollout."
echo "Reload Prometheus on the monitoring host: docker compose restart prometheus"
