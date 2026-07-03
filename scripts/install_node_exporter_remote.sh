#!/usr/bin/env bash
set -euo pipefail

# Install node_exporter on CCDL ERP servers as systemd service.

DRY_RUN="${DRY_RUN:-true}"
NODE_EXPORTER_VERSION="${NODE_EXPORTER_VERSION:-1.8.2}"
NODE_EXPORTER_USER="${NODE_EXPORTER_USER:-node_exporter}"
SSH_TIMEOUT="${SSH_TIMEOUT:-20}"

# Format: "ip|ssh_port|username|password"
HOSTS=(
  "10.10.21.5|9841|ccdlerp|CCDL@ERP0pen"   # CCDL-Live Server 1
  "10.10.21.6|9841|ccdlerp|CCDL@ERP0pen"   # CCDL Backup Server
  "10.10.21.11|9841|ccdlerp|CCDL@ERP0pen"     # CCDL Observatory Server
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
VERSION="__NODE_EXPORTER_VERSION__"
NE_USER="__NODE_EXPORTER_USER__"
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

TAR="node_exporter-${VERSION}.linux-${GOARCH}.tar.gz"
URL="https://github.com/prometheus/node_exporter/releases/download/v${VERSION}/${TAR}"
TMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

if ! id -u "$NE_USER" >/dev/null 2>&1; then
  run_sudo useradd --no-create-home --shell /usr/sbin/nologin "$NE_USER"
fi

curl -fsSL "$URL" -o "$TMP_DIR/$TAR"
tar -xzf "$TMP_DIR/$TAR" -C "$TMP_DIR"

run_sudo install -m 0755 "$TMP_DIR/node_exporter-${VERSION}.linux-${GOARCH}/node_exporter" /usr/local/bin/node_exporter
run_sudo chown root:root /usr/local/bin/node_exporter

sudo -S -p '' bash -c "cat > /etc/systemd/system/node_exporter.service <<'UNIT'
[Unit]
Description=Prometheus Node Exporter
After=network-online.target
Wants=network-online.target

[Service]
User=node_exporter
Group=node_exporter
Type=simple
ExecStart=/usr/local/bin/node_exporter --web.listen-address=:9100 --collector.systemd
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
UNIT" <<<"$SUDO_PASSWORD"

run_sudo systemctl daemon-reload
run_sudo systemctl enable --now node_exporter
run_sudo systemctl is-active --quiet node_exporter
curl -fsS http://127.0.0.1:9100/metrics >/dev/null
echo "node_exporter installed and running"
EOF
)

REMOTE_SCRIPT="${REMOTE_SCRIPT/__NODE_EXPORTER_VERSION__/$NODE_EXPORTER_VERSION}"
REMOTE_SCRIPT="${REMOTE_SCRIPT/__NODE_EXPORTER_USER__/$NODE_EXPORTER_USER}"

for host in "${HOSTS[@]}"; do
  IFS='|' read -r ip port username password <<<"$host"
  echo "----"
  echo "Target: ${ip}:${port} (${username})"
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[DRY-RUN] Would install node_exporter v${NODE_EXPORTER_VERSION} via systemd on ${ip}"
    continue
  fi

  REMOTE_SCRIPT_WITH_SUDO="${REMOTE_SCRIPT/__SUDO_PASSWORD__/$password}"
  run_remote "$password" "$port" "$username" "$ip" "$REMOTE_SCRIPT_WITH_SUDO"
done

echo "----"
echo "Completed node_exporter rollout."
