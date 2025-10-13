#!/usr/bin/env bash
# Installer for os-updates-exporter (Go binary) – minimal, systemd + daily self-update
# Targets exporter version: uses GitHub releases/latest assets
set -euo pipefail
IFS=$'\n\t'; umask 0027

SERVICE="os-updates-exporter"
BIN="/usr/local/bin/os-updates-exporter"
ENV_FILE="/etc/os-updates-exporter.env"
SERVICE_FILE="/etc/systemd/system/${SERVICE}.service"
TIMER_FILE="/etc/systemd/system/${SERVICE}.timer"
UPD_SERVICE_FILE="/etc/systemd/system/${SERVICE}-update.service"
UPD_TIMER_FILE="/etc/systemd/system/${SERVICE}-update.timer"

have(){ command -v "$1" >/dev/null 2>&1; }
is_systemd(){ have systemctl && [[ -d /run/systemd/system ]]; }
log(){ printf '%s installer[%d]: %s\n' "$(date -Is)" "$$" "$*" >&2; }
die(){ echo "ERROR: $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "run as root"

arch_norm(){ case "$(uname -m)" in x86_64|amd64) echo amd64;; aarch64|arm64) echo arm64;; armv7l) echo armv7;; *) echo amd64;; esac; }

detect_mgr(){
  have apt-get && { echo apt; return; }
  have dnf && { echo dnf; return; }
  have yum && { echo yum; return; }
  have zypper && { echo zypper; return; }
  echo none
}

install_deps(){
  case "$1" in
    apt)  export DEBIAN_FRONTEND=noninteractive; apt-get update -qq || true; apt-get install -y -qq curl ca-certificates tar coreutils findutils procps gnupg || true ;;
    dnf)  dnf -q makecache --timer || true; dnf -y -q install curl ca-certificates tar coreutils findutils procps-ng gnupg2 || true ;;
    yum)  yum -q makecache fast || true; yum -y -q install curl ca-certificates tar coreutils findutils procps-ng gnupg2 || true ;;
    zypper) zypper -qn refresh || true; zypper -qn install -y curl ca-certificates tar coreutils findutils procps gpg2 || true ;;
  esac
}

legacy_cleanup(){
  log "legacy cleanup"
  local old_units=( "os_updates_exporter" "os-updates-exporter" "node-exporter-os-updates" )
  for n in "${old_units[@]}"; do
    systemctl disable --now "${n}.timer" 2>/dev/null || true
    systemctl disable --now "${n}.service" 2>/dev/null || true
    rm -f "/etc/systemd/system/${n}.service" "/etc/systemd/system/${n}.timer" || true
  done
  systemctl daemon-reload 2>/dev/null || true
  local tmpc; tmpc="$(mktemp)"
  crontab -l 2>/dev/null | grep -vE "# (os[-_]updates[-_]exporter|os[_-]updates[_-]export\.sh|node-exporter-os-updates)" > "$tmpc" || true
  crontab "$tmpc" 2>/dev/null || true; rm -f "$tmpc" || true
  for p in /usr/local/bin/os_updates_export.sh /usr/sbin/os_updates_export.sh /usr/local/sbin/os-updates-exporter.sh /usr/local/bin/os-updates-exporter.sh; do
    [[ -f $p ]] && rm -f "$p" || true
  done
}

detect_textfile_dir(){
  local d
  d="$(ps -eo args | sed -n 's/.*--collector.textfile.directory=\([^[:space:]]\+\).*/\1/p' | head -n1 || true)"
  [[ -n "$d" ]] || d="/var/lib/node_exporter"
  echo "$d"
}

write_env(){
  [[ -f "$ENV_FILE" ]] && return
  cat >"$ENV_FILE"<<EOF
# os-updates-exporter ENV
#TEXTFILE_DIR=/var/lib/node_exporter
PATCH_THRESHOLD=3
INSTALL_INTERVAL=15m
REPO_DETAILS=0
TOPN_PACKAGES=0
MW_START=
MW_END=
REPO_HEAD_TIMEOUT=5s
PKGMGR_TIMEOUT=90s
EOF
  chmod 0644 "$ENV_FILE"
}

install_binary_from_release(){
  local arch url tmp code
  arch="$(arch_norm)"
  url="https://github.com/R4VXN/Prometheus/releases/latest/download/os-updates-exporter_Linux_${arch}.tar.gz"
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' RETURN
  code="$(curl -sSI "$url" | awk '/^HTTP/{print $2}' | tail -1)"
  [[ "$code" == "200" ]] || return 1
  curl -fsSL "$url" -o "$tmp/bin.tgz"
  tar -xzf "$tmp/bin.tgz" -C "$tmp"
  install -m0755 "$tmp/os-updates-exporter" "$BIN"
}

write_units(){
  local textdir; textdir="$(detect_textfile_dir)"
  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=OS Updates Prometheus Exporter (Go)
After=network-online.target

[Service]
Type=oneshot
EnvironmentFile=-${ENV_FILE}
ExecStart=${BIN}
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
ProtectSystem=full
ProtectHome=true
PrivateTmp=true
NoNewPrivileges=true
CapabilityBoundingSet=
ReadWritePaths=${textdir}
EOF

  local interval; interval="$(grep -E '^INSTALL_INTERVAL=' "$ENV_FILE" | cut -d= -f2 || true)"
  [[ -n "$interval" ]] || interval="15m"
  cat > "$TIMER_FILE" <<EOF
[Unit]
Description=Run ${SERVICE} periodically
[Timer]
OnBootSec=5m
OnUnitActiveSec=${interval}
RandomizedDelaySec=5m
Persistent=true
[Install]
WantedBy=timers.target
EOF

  cat > "$UPD_SERVICE_FILE" <<'EOF'
[Unit]
Description=os-updates-exporter self-update (GitHub releases)
After=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/bin/env bash -c '
set -euo pipefail
BIN="/usr/local/bin/os-updates-exporter"
BASE="os-updates-exporter_Linux"
arch="$(uname -m)"; case "$arch" in x86_64|amd64) arch=amd64;; aarch64|arm64) arch=arm64;; armv7l) arch=armv7;; *) arch=amd64;; esac
URL="https://github.com/R4VXN/Prometheus/releases/latest/download/${BASE}_${arch}.tar.gz"
tmp="$(mktemp -d)"; trap "rm -rf \"$tmp\"" EXIT
code="$(curl -sSI "$URL" | awk "/^HTTP/{print \$2}" | tail -1)"
[[ "$code" == "200" ]] || exit 0
curl -fsSL "$URL" -o "$tmp/bin.tgz"
tar -xzf "$tmp/bin.tgz" -C "$tmp"
NEW="$tmp/os-updates-exporter"; [[ -x "$NEW" ]] || exit 0
curv="$($BIN --version 2>/dev/null | awk "{print \$2}" || echo 0.0.0)"
newv="$($NEW --version 2>/dev/null | awk "{print \$2}" || echo 0.0.0)"
if [[ "$(printf "%s\n%s\n" "$curv" "$newv" | sort -V | tail -1)" == "$newv" && "$curv" != "$newv" ]]; then
  install -m0755 "$NEW" "$BIN"
fi
'
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
EOF

  cat > "$UPD_TIMER_FILE" <<'EOF'
[Unit]
Description=Run os-updates-exporter self-update daily
[Timer]
OnCalendar=daily
RandomizedDelaySec=1h
Persistent=true
[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now "${SERVICE}.timer" "${SERVICE}-update.timer"
}

main(){
  legacy_cleanup
  install_deps "$(detect_mgr)"
  write_env
  install_binary_from_release || die "Kein Release-Asset gefunden. Bitte Release v0.5 mit Tars hochladen."
  mkdir -p "$(detect_textfile_dir)"; chmod 0750 "$(detect_textfile_dir)" 2>/dev/null || true
  write_units
  log "done. Check: systemctl status ${SERVICE}.timer && ${BIN} --version"
}
main "$@"
