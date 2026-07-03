# CCDL ERP Monitoring

Dockerized monitoring stack for CCDL Odoo ERP servers: Prometheus, Grafana, Alertmanager, and Postgres exporters. Metrics-only — no Loki/log aggregation.

## Servers

| Name | IP | SSH | Monitored |
|------|-----|-----|-----------|
| CCDL-Live Server 1 | `192.168.3.245` | `9841` / `ccdlerp` | node_exporter, Patroni (`:8008`), Postgres (`:5000`) |
| CCDL Backup Server | `192.168.3.240` | `9841` / `ccdlerp` | node_exporter, Patroni (`:8008`), Postgres (`:5000`) |
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

Runs as systemd on port `9100` with `--collector.systemd` (enables Server Alive, Docker, and Nginx status in Grafana).

```bash
# Dry-run first (default)
./scripts/install_node_exporter_remote.sh

# Deploy to all 3 servers
DRY_RUN=false ./scripts/install_node_exporter_remote.sh
```

### 2. Enable pg_stat_statements (Live + Backup only)

Required for Postgres query metrics in Grafana. Postgres must have `pg_stat_statements` in `shared_preload_libraries` (restart required if not already set).

```bash
./scripts/enable_pg_stat_statements.sh          # dry-run
DRY_RUN=false ./scripts/enable_pg_stat_statements.sh
```

### 3. Start the monitoring stack

```bash
docker compose up -d
```

### 4. Access

| Service | URL | Default login |
|---------|-----|---------------|
| Grafana | http://localhost:3000 | `admin` / `admin` |
| Prometheus | http://localhost:9090 | — |
| Alertmanager | http://localhost:9093 | — |

**Home dashboard:** CCDL ERP Overview — server health table (Alive / Docker / Nginx), Patroni cluster status, Postgres summary.

**Drill-down dashboards** (folder: Server health internal):

- Patroni Odoo (CCDL)
- Postgres Odoo (CCDL)

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

## Troubleshooting

| Issue | Check |
|-------|-------|
| Targets DOWN | Firewall allows `9100`, `5000`, `8008` from Docker host to server IPs |
| Postgres exporter auth failed | Verify `odoo` / `123456` on port `5000` |
| Docker/Nginx shows N/A (gray) | Service not installed on that host (expected on Observatory) |
| pg_stat_statements panels empty | Run `enable_pg_stat_statements.sh`; confirm `shared_preload_libraries` |
| No alert emails | Confirm SMTP credentials in `alertmanager/alertmanager.yml`; check Alertmanager UI |

## Security note

SSH and database credentials are embedded in install scripts per project requirements. Rotate passwords and prefer SSH keys in production.
