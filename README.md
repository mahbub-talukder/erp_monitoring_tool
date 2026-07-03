# CCDL ERP Monitoring

Dockerized monitoring stack for CCDL Odoo ERP servers: Prometheus, Grafana, Alertmanager, and Postgres exporters. Metrics-only — no Loki/log aggregation.

## Servers

| Name | IP | SSH | Monitored |
|------|-----|-----|-----------|
| CCDL-Live Server 1 | `10.10.21.5` | `9841` / `ccdlerp` | node_exporter, Patroni (`:8008`), Postgres (`:5000`) |
| CCDL Backup Server | `10.10.21.6` | `9841` / `ccdlerp` | node_exporter, Patroni (`:8008`), Postgres (`:5000`) |
| CCDL Observatory Server | `10.10.21.11` | `9841` / `ccdlerp` | node_exporter only (server health) |

**Postgres credentials:** user `odoo`, password `123456`, port `5000`, database `postgres`.

**Metrics retention:** 30 days (Prometheus TSDB).

## Prerequisites

On the machine running Docker:

- Docker and Docker Compose
- Network access to all three server IPs on ports `9100` (node_exporter), `5000` (Postgres), and `8008` (Patroni REST)

On your workstation (for remote install scripts):

- `sshpass` (`sudo apt-get install -y sshpass`)

## Quick start

### 1. Install node_exporter on all servers

Runs as systemd on port `9100` with `--collector.systemd` and textfile collector (enables Server Alive, Docker, Nginx status, and Odoo HTTP req/s in Grafana).

```bash
# Dry-run first (default)
./scripts/install_node_exporter_remote.sh

# Deploy to all 3 servers
DRY_RUN=false ./scripts/install_node_exporter_remote.sh
```

### 2. Install Odoo HTTP req/s collector (Live + Backup)

Counts Odoo **werkzeug** access-log lines from Docker (`odoo_server1` / `odoo_server2`) and exposes `odoo_http_requests_total` via node_exporter textfile. No nginx required.

```bash
./scripts/install_odoo_http_exporter_remote.sh          # dry-run
DRY_RUN=false ./scripts/install_odoo_http_exporter_remote.sh
```

Health checks (`/web/health`), longpolling, and websocket traffic are excluded.

### 3. Enable pg_stat_statements (Live + Backup only)

Required for Postgres query metrics in Grafana. Postgres must have `pg_stat_statements` in `shared_preload_libraries` (restart required if not already set).

```bash
./scripts/enable_pg_stat_statements.sh          # dry-run
DRY_RUN=false ./scripts/enable_pg_stat_statements.sh
```

### 4. Start the monitoring stack

```bash
docker compose up -d
```

### 5. Access

| Service | URL | Default login |
|---------|-----|---------------|
| Grafana | http://localhost:3000 | `admin` / `admin` |
| Prometheus | http://localhost:9090 | — |
| Alertmanager | http://localhost:9093 | — |

**Home dashboard:** CCDL ERP Overview — server health, Odoo req/s, Patroni leader/replica, lag and timeline graphs.

**Drill-down dashboards** (folder: Server health internal):

- Patroni Odoo (CCDL)
- Postgres Odoo (CCDL)

### Odoo request rate (werkzeug log collector)

The **Odoo Application Req/s** panel reads `odoo_http_requests_total` from node_exporter on Live and Backup:

```promql
sum(rate(odoo_http_requests_total{job="node", server=~"live|backup"}[5m]))
```

Install with `scripts/install_odoo_http_exporter_remote.sh`. Verify on a server:

```bash
curl -s http://127.0.0.1:9100/metrics | grep odoo_http_requests_total
```

## Project layout

```
erp-monitoring/
├── docker-compose.yml
├── prometheus/
│   ├── prometheus.yml
│   ├── alerts.yml
│   └── service_health_rules.yml
├── alertmanager/
│   ├── alertmanager.yml
│   └── templates/custom_email.tmpl
├── postgres/
│   └── postgres_exporter_queries_odoo.yaml
├── grafana/
│   ├── Dockerfile
│   └── provisioning/
├── scripts/
│   ├── install_node_exporter_remote.sh
│   ├── install_odoo_http_exporter_remote.sh
│   ├── install_nginx_exporter_remote.sh
│   └── enable_pg_stat_statements.sh
└── README.md
```

All server IPs and credentials are hardcoded in config files (no `.env` or config generation step).

## Alertmanager email

Copied from the MIME monitoring project with email **enabled**:

- SMTP: `mail.mimebd.com:587`
- Recipients: `saif.ahmed@cg-bd.com`, `mahbub.alum@cg-bd.com`, `hasin.arman@cg-bd.com`
- Alerts with `notify=infra_hosts` route to email (server down, Docker/Nginx down, high CPU/RAM/disk, Patroni lag, Patroni node count)

## Verify

1. **Prometheus → Status → Targets** — all `node`, `patroni_odoo`, and `postgres_odoo` targets should be UP.
2. **Grafana → CCDL ERP Overview** — three server rows with Server Alive, Docker status, Nginx status.
3. **Patroni Odoo** service row shows `2/2` when both DB nodes are healthy.
4. **Odoo Application Req/s** — shows `0` or higher after `install_odoo_http_exporter_remote.sh` (not **No data**).

## Troubleshooting

| Issue | Check |
|-------|-------|
| Targets DOWN | Firewall allows `9100`, `5000`, `8008` from Docker host to server IPs |
| Postgres exporter auth failed | Verify `odoo` / `123456` on port `5000` |
| Docker/Nginx shows N/A (gray) | Service not installed on that host (expected on Observatory) |
| pg_stat_statements panels empty | Run `enable_pg_stat_statements.sh`; confirm `shared_preload_libraries` |
| Odoo Req/s shows No data | Run `install_odoo_http_exporter_remote.sh`; confirm `odoo_http_requests_total` on `:9100` |
| Odoo Req/s stuck at 0 | Generate Odoo HTTP traffic; check `systemctl status odoo_http_collector.timer` |
| No alert emails | Confirm SMTP credentials in `alertmanager/alertmanager.yml`; check Alertmanager UI |

## Security note

SSH and database credentials are embedded in install scripts per project requirements. Rotate passwords and prefer SSH keys in production.
