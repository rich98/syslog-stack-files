#!/usr/bin/env bash
# Install Loki, Promtail, and Grafana on RHEL 9+
# - Installs Grafana via official RPM repo (dnf)
# - Installs Loki/Promtail from upstream release binaries
# - Creates system users, directories, configs, and systemd units
# - Provisions Grafana datasource for Loki
# - Opens firewall ports 3000 (Grafana) and 3100 (Loki)
# - Idempotent: safe to re-run
set -euo pipefail

### --- CONFIGURABLE DEFAULTS (override via env) -----------------------------
: "${LOKI_VERSION:=2.9.7}"         # set desired Loki/Promtail version
: "${PROMTAIL_VERSION:=${LOKI_VERSION}}"
: "${GRAFANA_PACKAGE:=grafana}"     # grafana (OSS)
: "${GRAFANA_PORT:=3000}"
: "${LOKI_HTTP_PORT:=3100}"
: "${PROMTAIL_HTTP_PORT:=9080}"
: "${RETENTION_DAYS:=14}"          # log retention in days (Loki table_manager)
: "${OPEN_LOKI_PORT:=yes}"         # yes/no (open 3100 for remote push/queries)
: "${DOWNLOAD_BASE:=https://github.com/grafana/loki/releases/download}"
# ---------------------------------------------------------------------------

log() { printf -- "[%s] %s\n" "$(date +'%F %T')" "$*" ; }

require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "This script must run as root." >&2
    exit 1
  fi
}

check_rhel9() {
  if [[ -r /etc/redhat-release ]]; then
    if ! grep -Eq 'release 9' /etc/redhat-release; then
      log "Warning: This script targets RHEL 9; detected: $(cat /etc/redhat-release)"
    fi
  fi
}

detect_arch() {
  case "$(uname -m)" in
    x86_64)   ARCH="amd64" ;;
    aarch64)  ARCH="arm64" ;;
    arm64)    ARCH="arm64" ;;
    *)        echo "Unsupported architecture: $(uname -m)" >&2; exit 2 ;;
  esac
  log "Detected architecture: ${ARCH}"
}

install_prereqs() {
  log "Installing prerequisites (dnf, wget, unzip, tar, firewalld, systemd utilities)..."
  dnf -y install wget unzip tar coreutils shadow-utils curl >/dev/null
  # firewalld may be disabled in some environments; install and enable if present
  if ! rpm -q firewalld >/dev/null 2>&1; then
    dnf -y install firewalld >/dev/null || true
  fi
  systemctl enable --now firewalld >/dev/null 2>&1 || true
}

create_users_and_dirs() {
  log "Creating system users and directories..."
  id -u loki >/dev/null 2>&1 || useradd --system --home-dir /var/lib/loki --shell /sbin/nologin loki
  id -u promtail >/dev/null 2>&1 || useradd --system --home-dir /var/lib/promtail --shell /sbin/nologin promtail

  install -d -o loki -g loki -m 0755 /etc/loki /var/lib/loki /var/lib/loki/index /var/lib/loki/boltdb-cache /var/lib/loki/chunks /var/lib/loki/compactor /etc/loki/rules
  install -d -o promtail -g promtail -m 0755 /etc/promtail /var/lib/promtail
}

install_loki_promtail_binaries() {
  detect_arch
  local loki_url="${DOWNLOAD_BASE}/v${LOKI_VERSION}/loki-linux-${ARCH}.zip"
  local promtail_url="${DOWNLOAD_BASE}/v${PROMTAIL_VERSION}/promtail-linux-${ARCH}.zip"
  local bindir="/usr/local/bin"

  log "Fetching Loki ${LOKI_VERSION} from ${loki_url}"
  wget -qO /tmp/loki.zip "${loki_url}"
  log "Fetching Promtail ${PROMTAIL_VERSION} from ${promtail_url}"
  wget -qO /tmp/promtail.zip "${promtail_url}"

  log "Installing binaries to ${bindir}"
  unzip -o -q /tmp/loki.zip -d /tmp
  unzip -o -q /tmp/promtail.zip -d /tmp
  install -m 0755 /tmp/loki "${bindir}/loki"
  install -m 0755 /tmp/promtail "${bindir}/promtail"
  rm -f /tmp/loki /tmp/promtail /tmp/loki.zip /tmp/promtail.zip

  log "Setting capabilities (allow binding low ports not required; none set)."
}

write_loki_config() {
  local cfg="/etc/loki/loki-config.yaml"
  log "Writing Loki configuration to ${cfg}"
  cat > "${cfg}" <<EOF
server:
  http_listen_port: ${LOKI_HTTP_PORT}
  grpc_listen_port: 9096

common:
  path_prefix: /var/lib/loki
  storage:
    filesystem:
      chunks_directory: /var/lib/loki/chunks
      rules_directory: /etc/loki/rules
  replication_factor: 1
  ring:
    kvstore:
      store: inmemory

schema_config:
  configs:
    - from: 2024-01-01
      store: boltdb-shipper
      object_store: filesystem
      schema: v13
      index:
        prefix: index_
        period: 24h

storage_config:
  boltdb_shipper:
    active_index_directory: /var/lib/loki/index
    cache_location: /var/lib/loki/boltdb-cache
    shared_store: filesystem
  filesystem:
    directory: /var/lib/loki/chunks

limits_config:
  reject_old_samples: true
  reject_old_samples_max_age: 168h
  ingestion_rate_mb: 10
  ingestion_burst_size_mb: 20

chunk_store_config:
  max_look_back_period: 0s

table_manager:
  retention_deletes_enabled: true
  retention_period: ${RETENTION_DAYS}d

compactor:
  working_directory: /var/lib/loki/compactor
  shared_store: filesystem
EOF
  chown loki:loki "${cfg}"
  chmod 0644 "${cfg}"
}

write_promtail_config() {
  local cfg="/etc/promtail/promtail-config.yaml"
  log "Writing Promtail configuration to ${cfg}"
  cat > "${cfg}" <<'EOF'
server:
  http_listen_port: 9080

positions:
  filename: /var/lib/promtail/positions.yaml

clients:
  - url: http://localhost:3100/loki/api/v1/push

scrape_configs:
  - job_name: varlogs
    static_configs:
      - targets: [localhost]
        labels:
          job: varlogs
          __path__: /var/log/**/*.log

  - job_name: journald
    journal:
      path: /var/log/journal
      max_age: 12h
      labels:
        job: systemd-journal
    relabel_configs:
      - source_labels: ['__journal__systemd_unit']
        target_label: 'unit'
EOF
  # Post-process to insert the configured port
  sed -i "s/http_listen_port: 9080/http_listen_port: ${PROMTAIL_HTTP_PORT}/" "${cfg}"
  chown -R promtail:promtail /etc/promtail /var/lib/promtail
  chmod 0644 "${cfg}"
}

write_systemd_units() {
  log "Creating systemd unit files..."

  cat > /etc/systemd/system/loki.service <<EOF
[Unit]
Description=Grafana Loki log aggregation system
Documentation=https://grafana.com/docs/loki/latest/
After=network-online.target
Wants=network-online.target

[Service]
User=loki
Group=loki
Type=simple
ExecStart=/usr/local/bin/loki -config.file=/etc/loki/loki-config.yaml
Restart=on-failure
RestartSec=5s
LimitNOFILE=65536
AmbientCapabilities=
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true

[Install]
WantedBy=multi-user.target
EOF

  cat > /etc/systemd/system/promtail.service <<EOF
[Unit]
Description=Promtail log forwarder
Documentation=https://grafana.com/docs/loki/latest/clients/promtail/
After=network-online.target
Wants=network-online.target

[Service]
User=promtail
Group=promtail
Type=simple
ExecStart=/usr/local/bin/promtail -config.file=/etc/promtail/promtail-config.yaml
Restart=on-failure
RestartSec=5s
LimitNOFILE=65536
AmbientCapabilities=
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
}

install_grafana() {
  if [[ ! -f /etc/yum.repos.d/grafana.repo ]]; then
    log "Configuring Grafana YUM repository..."
    cat > /etc/yum.repos.d/grafana.repo <<'EOF'
[grafana]
name=Grafana OSS
baseurl=https://packages.grafana.com/oss/rpm
repo_gpgcheck=1
enabled=1
gpgcheck=1
gpgkey=https://packages.grafana.com/gpg.key
sslverify=1
EOF
  fi

  log "Installing Grafana package (${GRAFANA_PACKAGE})..."
  dnf -y install "${GRAFANA_PACKAGE}" >/dev/null

  log "Enabling Grafana server..."
  systemctl enable --now grafana-server
}

provision_grafana_loki_ds() {
  local dsdir="/etc/grafana/provisioning/datasources"
  local dsfile="${dsdir}/loki.yaml"
  log "Provisioning Grafana Loki datasource at ${dsfile}"
  install -d -o grafana -g grafana -m 0755 "${dsdir}"
  cat > "${dsfile}" <<EOF
apiVersion: 1
datasources:
  - name: Loki
    type: loki
    access: proxy
    url: http://localhost:${LOKI_HTTP_PORT}
    isDefault: true
    editable: true
EOF
  chown grafana:grafana "${dsfile}"
  chmod 0644 "${dsfile}"
  # Trigger Grafana to reload provisioning
  systemctl restart grafana-server
}

configure_firewalld() {
  # Open Grafana web UI port
  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
    log "Configuring firewalld rules..."
    firewall-cmd --permanent --add-port=${GRAFANA_PORT}/tcp || true
    if [[ "${OPEN_LOKI_PORT}" == "yes" ]]; then
      firewall-cmd --permanent --add-port=${LOKI_HTTP_PORT}/tcp || true
    fi
    firewall-cmd --reload || true
  else
    log "firewalld not active; skip firewall changes."
  fi
}

enable_and_start() {
  log "Starting Loki and Promtail services..."
  systemctl enable --now loki
  systemctl enable --now promtail

  log "Summary of service status:"
  systemctl --no-pager --full status loki | sed -n '1,10p' || true
  systemctl --no-pager --full status promtail | sed -n '1,10p' || true
  systemctl --no-pager --full status grafana-server | sed -n '1,10p' || true
}

hardening_notes() {
  cat <<'EON' >&2
[Note] Additional hardening (optional, not applied automatically):
  - Verify upstream binary checksums/signatures before installation.
  - Bind Loki to localhost if it is not intended to serve remote clients:
      server:
        http_listen_address: 127.0.0.1
    and set OPEN_LOKI_PORT=no (default allows 3100/tcp).
  - Configure TLS/Reverse Proxy for Grafana (nginx/Apache) and restrict network access.
  - Create Grafana admin password securely (GF_SECURITY_ADMIN_PASSWORD or provisioning).
  - Consider SELinux boolean and fapolicyd policies in high-hardening environments.
EON
}

main() {
  require_root
  check_rhel9
  install_prereqs
  create_users_and_dirs
  install_loki_promtail_binaries
  write_loki_config
  write_promtail_config
  write_systemd_units
  install_grafana
  provision_grafana_loki_ds
  configure_firewalld
  enable_and_start
  hardening_notes

  log "Installation complete."
  log "Grafana:   http://<server-ip>:${GRAFANA_PORT}  (default admin/admin; change on first login)"
  log "Loki API:  http://<server-ip>:${LOKI_HTTP_PORT}"
  log "Promtail:  http://<server-ip>:${PROMTAIL_HTTP_PORT}/metrics"
  log "Retention: ${RETENTION_DAYS} day(s). Adjust via RETENTION_DAYS env."
}

main "$@"

