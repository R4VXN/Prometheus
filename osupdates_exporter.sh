#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'
umask 0027
export LC_ALL=C
PATH=/usr/sbin:/usr/bin:/sbin:/bin

# ──────────────────────────────────────────────────────────────────────────────
# Defaults (per ENV überschreibbar oder via /etc/os-updates-exporter.env)
: "${PATCH_THRESHOLD:=3}"
: "${OSUPDATER_OUTPUT_DIR:=}"          # leer = autodetect von laufendem Exporter oder Fallback /var/lib/node_exporter
: "${APT_UPDATE_TIMEOUT:=120}"         # Sekunden
: "${INSTALL_INTERVAL:=1h}"            # systemd Timer Interval / Cron-Frequenz (z.B. 30m, 1h)
# ──────────────────────────────────────────────────────────────────────────────

SELF="$(readlink -f "${BASH_SOURCE[0]}")"
INSTALL_PATH="/usr/local/sbin/os_updates_export.sh"
ENV_FILE="/etc/os-updates-exporter.env"
SERVICE="os-updates-exporter"
SERVICE_FILE="/etc/systemd/system/${SERVICE}.service"
TIMER_FILE="/etc/systemd/system/${SERVICE}.timer"
CRON_MARKER="# ${SERVICE}"
LOCK_FILE="/run/os_updates.lock"

log(){ printf '%s %s[%d]: %s\n' "$(date -Is)" "${SERVICE}" "$$" "$*" >&2; }

have_cmd(){ command -v "$1" >/dev/null 2>&1; }
have_systemd(){ have_cmd systemctl && [[ -d /run/systemd/system ]]; }

# ──────────────────────────────────────────────────────────────────────────────
# Textfile-Dir Detection & Exporter-User
detect_textfile_dir() {
  if [[ -n "${OSUPDATER_OUTPUT_DIR:-}" ]]; then
    printf '%s' "${OSUPDATER_OUTPUT_DIR%/}"
    return
  fi
  local d
  d="$(ps -eo args | sed -n 's/.*--collector.textfile.directory=\([^[:space:]]\+\).*/\1/p' | head -n1)"
  [[ -n "$d" ]] || d="/var/lib/node_exporter"
  printf '%s' "$d"
}

detect_exporter_identity() {
  local mode="generic" u g
  if systemctl list-units --type=service --all 2>/dev/null | grep -q -E '^alloy\.service'; then
    mode="alloy"; u="alloy"; g="alloy"
  elif systemctl list-units --type=service --all 2>/dev/null | grep -q -E '^node_exporter\.service' || have_cmd node_exporter; then
    mode="node_exporter"; u="node_exporter"; g="node_exporter"
  else
    u="$(id -un)"; g="$(id -gn)"
  fi
  getent passwd "$u" >/dev/null || u="$(id -un)"
  getent group  "$g" >/dev/null || g="$(id -gn)"
  printf '%s:%s:%s' "$mode" "$u" "$g"
}

# ──────────────────────────────────────────────────────────────────────────────
# Error Trap: bei Fehlern trotzdem eine Metrik schreiben
OUTPUT_DIR="$(detect_textfile_dir)"
TMP_FILE=""
on_error() {
  local line="$1" rc="$2"
  log "ERROR at line ${line}, rc=${rc}"
  mkdir -p "$OUTPUT_DIR" || true
  local fail_tmp
  fail_tmp="$(mktemp -p "$OUTPUT_DIR" .os_updates.prom.fail.XXXXXX 2>/dev/null || echo "")"
  if [[ -n "$fail_tmp" ]]; then
    {
      printf '# HELP os_updates_scrape_success 1 if script finished without fatal error\n'
      printf '# TYPE os_updates_scrape_success gauge\n'
      printf 'os_updates_scrape_success 0\n'
      printf '# HELP os_updates_last_run_timestamp_seconds Unix timestamp of last run (failed)\n'
      printf '# TYPE os_updates_last_run_timestamp_seconds gauge\n'
      printf 'os_updates_last_run_timestamp_seconds %d\n' "$(date +%s)"
    } > "$fail_tmp"
    mv -f "$fail_tmp" "${OUTPUT_DIR}/os_updates.prom"
  fi
  exit "$rc"
}
trap 'on_error ${LINENO} $?' ERR
trap '[[ -n "${TMP_FILE:-}" && -f "$TMP_FILE" ]] && rm -f "$TMP_FILE" || true' EXIT INT TERM

# ──────────────────────────────────────────────────────────────────────────────
# Helper: locking
acquire_lock() {
  mkdir -p /run || true
  if have_cmd flock; then
    exec 9>"$LOCK_FILE"
    flock -n 9 || { log "another instance running, exit"; exit 0; }
  else
    log "WARNING: flock not found; proceeding without single-instance lock"
  fi
}

# ──────────────────────────────────────────────────────────────────────────────
# Prometheus label escaping
escape_label() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  printf '%s' "$s"
}

# ──────────────────────────────────────────────────────────────────────────────
# Locked packages
get_locked() {
  case "$1" in
    apt)    apt-mark showhold 2>/dev/null || true ;;
    dnf)    dnf versionlock list 2>/dev/null | awk '/^[0-9]/{print $2}' || true ;;
    yum)    yum versionlock list 2>/dev/null | awk '/^[0-9]/{print $2}' || true ;;
    zypper) zypper -q locks --type package 2>/dev/null | awk 'NR>2 {print $3}' || true ;;
    *)      return 0 ;;
  esac
}

# ──────────────────────────────────────────────────────────────────────────────
# Reboot detection
reboot_required() {
  local mgr="$1"
  if [[ -f /var/run/reboot-required ]]; then return 0; fi
  if [[ "$mgr" =~ ^(dnf|yum)$ ]]; then
    if have_cmd needs-restarting; then
      needs-restarting -r >/dev/null 2>&1 || return 0
    elif have_cmd dnf; then
      dnf -q needs-restarting -r >/dev/null 2>&1 || return 0
    fi
  fi
  if [[ "$mgr" == "zypper" ]] && have_cmd zypper; then
    zypper -q ps -s 2>/dev/null | grep -qi 'reboot' && return 0 || true
  fi
  return 1
}

# ──────────────────────────────────────────────────────────────────────────────
# Cache refresh
refresh_cache() {
  case "$1" in
    apt)
      if have_cmd timeout; then timeout "$APT_UPDATE_TIMEOUT" apt-get update -qq >/dev/null 2>&1 || true
      else apt-get update -qq >/dev/null 2>&1 || true; fi
      ;;
    dnf) dnf -q makecache --timer >/dev/null 2>&1 || true ;;
    yum) yum -q makecache fast >/dev/null 2>&1 || true ;;
    zypper) zypper -q refresh -s >/dev/null 2>&1 || true ;;
  esac
}

# ──────────────────────────────────────────────────────────────────────────────
# Package lists per manager
get_pkgs_apt() {
  local sim
  sim="$(apt-get -s upgrade 2>/dev/null || true)"
  if [[ -n "$sim" ]]; then
    printf '%s\n' "$sim" | awk '/^Inst /{print $2}' | sort -u
  else
    apt list --upgradable 2>/dev/null | awk -F'/' 'NR>1 {print $1}' | sort -u
  fi
}
get_sec_pkgs_apt() {
  apt-get -s upgrade 2>/dev/null | awk '/^Inst / && /security/{print $2}' | sort -u
}

strip_rpm_arch(){ sed 's/\.[^.[:space:]]\+$//'; }

get_pkgs_dnf(){ (dnf -q check-update 2>/dev/null || true) | awk '/^[[:alnum:]][^[:space:]]*/{print $1}' | strip_rpm_arch | sort -u; }
get_pkgs_yum(){ (yum -q check-update 2>/dev/null || true) | awk '/^[[:alnum:]][^[:space:]]*/{print $1}' | strip_rpm_arch | sort -u; }
get_pkgs_zypper(){ zypper -q list-updates --type package 2>/dev/null | awk 'NR>2 && $1 !~ /^Repository/ {print $3}' | sort -u; }

get_sec_pkgs_dnf(){
  dnf -q updateinfo info --available --security 2>/dev/null \
    | awk 'BEGIN{inlist=0} /^Updated packages:/ {inlist=1;next} inlist && NF==0 {inlist=0} inlist{print $1}' \
    | strip_rpm_arch | sort -u
}
get_sec_pkgs_yum(){
  yum -q update --security --assumeno 2>/dev/null \
    | awk '/^(Upgrading|Updating|Installing|Downgrading)\s*:/{grab=1;next} grab && NF==0{grab=0} grab{print $1}' \
    | strip_rpm_arch | sort -u
}

get_crit_count_dnf(){ dnf -q updateinfo list --available --sec-severity=Critical 2>/dev/null | grep -E '^(RHSA|ALSA|ELSA|FEDORA)-' | wc -l || true; }
get_crit_count_yum(){ yum -q updateinfo list --available --sec-severity=Critical 2>/dev/null | grep -E '^(RHSA|ALSA|ELSA|FEDORA)-' | wc -l || true; }

# ──────────────────────────────────────────────────────────────────────────────
# Collector
run_collector() {
  acquire_lock

  local ts_start="$(date +%s)"
  local mode user group info
  info="$(detect_exporter_identity)"; mode="${info%%:*}"; info="${info#*:}"; user="${info%%:*}"; group="${info#*:}"

  mkdir -p "$OUTPUT_DIR"
  TMP_FILE="$(mktemp -p "$OUTPUT_DIR" .os_updates.prom.XXXXXX)"
  chown "$user:$group" "$OUTPUT_DIR" 2>/dev/null || true
  chmod 0750 "$OUTPUT_DIR" 2>/dev/null || true

  local mgr count=0 sec_count=0 bugfix_count=0 crit_count=0 reboot=0
  if have_cmd apt-get; then mgr="apt"
  elif have_cmd dnf;   then mgr="dnf"
  elif have_cmd yum;   then mgr="yum"
  elif have_cmd zypper;then mgr="zypper"
  else
    echo "ERROR: Kein unterstützter Paketmanager gefunden." >&2
    exit 1
  fi

  refresh_cache "$mgr"

  local -a pkgs=() sec_pkgs=() locked=() filtered=()
  case "$mgr" in
    apt) mapfile -t pkgs < <(get_pkgs_apt); mapfile -t sec_pkgs < <(get_sec_pkgs_apt || true) ;;
    dnf) mapfile -t pkgs < <(get_pkgs_dnf); mapfile -t sec_pkgs < <(get_sec_pkgs_dnf || true); crit_count="$(get_crit_count_dnf || echo 0)";;
    yum) mapfile -t pkgs < <(get_pkgs_yum); mapfile -t sec_pkgs < <(get_sec_pkgs_yum || true); crit_count="$(get_crit_count_yum || echo 0)";;
    zypper) mapfile -t pkgs < <(get_pkgs_zypper) ;;
  esac

  mapfile -t locked < <(get_locked "$mgr" || true)
  if ((${#locked[@]})); then
    declare -A L=(); for l in "${locked[@]}"; do L["$l"]=1; done
    for p in "${pkgs[@]}"; do [[ -z "${L[$p]:-}" ]] && filtered+=("$p"); done
    pkgs=("${filtered[@]}")
  fi

  count="${#pkgs[@]}"; sec_count="${#sec_pkgs[@]}"; bugfix_count=$(( count - sec_count )); (( bugfix_count < 0 )) && bugfix_count=0
  reboot=0; if reboot_required "$mgr"; then reboot=1; fi

  local OS_ID="unknown" OS_VER="unknown"
  if [[ -r /etc/os-release ]]; then . /etc/os-release; OS_ID="${ID:-unknown}"; OS_VER="${VERSION_ID:-unknown}"; fi

  {
    printf '# HELP os_pending_updates Total pending updates by type\n'
    printf '# TYPE os_pending_updates gauge\n'
    printf 'os_pending_updates{manager="%s",type="security"} %d\n' "$mgr" "$sec_count"
    printf 'os_pending_updates{manager="%s",type="bugfix"} %d\n'   "$mgr" "$bugfix_count"

    printf '# HELP os_pending_cves_total Number of critical security advisories (not packages)\n'
    printf '# TYPE os_pending_cves_total gauge\n'
    printf 'os_pending_cves_total{severity="Critical"} %d\n' "$crit_count"

    printf '# HELP os_pending_reboots Whether a reboot is pending\n'
    printf '# TYPE os_pending_reboots gauge\n'
    printf 'os_pending_reboots %d\n' "$reboot"

    printf '# HELP os_updates_compliant Whether update count <= threshold\n'
    printf '# TYPE os_updates_compliant gauge\n'
    printf 'os_updates_compliant %d\n' $(( count <= PATCH_THRESHOLD ? 1 : 0 ))

    printf '# HELP os_updates_info Static info about this collector\n'
    printf '# TYPE os_updates_info gauge\n'
    printf 'os_updates_info{manager="%s",exporter="%s",output_dir="%s",os="%s",os_version="%s",threshold="%s"} 1\n' \
      "$mgr" "$mode" "$(escape_label "$OUTPUT_DIR")" "$OS_ID" "$OS_VER" "$PATCH_THRESHOLD"

    printf '# HELP os_updates_last_run_timestamp_seconds Unix timestamp of last successful run\n'
    printf '# TYPE os_updates_last_run_timestamp_seconds gauge\n'
    printf 'os_updates_last_run_timestamp_seconds %d\n' "$ts_start"

    printf '# HELP os_updates_run_duration_seconds Script runtime in seconds\n'
    printf '# TYPE os_updates_run_duration_seconds gauge\n'
    printf 'os_updates_run_duration_seconds %d\n' "$(( $(date +%s) - ts_start ))"

    printf '# HELP os_updates_scrape_success 1 if script finished without fatal error\n'
    printf '# TYPE os_updates_scrape_success gauge\n'
    printf 'os_updates_scrape_success 1\n'

    printf '# HELP os_pending_update_info Detailed per-package info\n'
    printf '# TYPE os_pending_update_info gauge\n'
  } >> "$TMP_FILE"

  local pkg pkg_esc
  for pkg in "${pkgs[@]:-}"; do
    [[ -z "$pkg" ]] && continue
    pkg_esc="$(escape_label "$pkg")"
    printf 'os_pending_update_info{manager="%s",package="%s"} 1\n' "$mgr" "$pkg_esc"
  done >> "$TMP_FILE"

  # Atomic replace + perms
  mv -f "$TMP_FILE" "${OUTPUT_DIR}/os_updates.prom"
  local _m _u _g; IFS=: read -r _m _u _g <<<"$(detect_exporter_identity)"
  chown "$_u:$_g" "${OUTPUT_DIR}/os_updates.prom" 2>/dev/null || true
  chmod 0640 "${OUTPUT_DIR}/os_updates.prom" 2>/dev/null || true
}

# ──────────────────────────────────────────────────────────────────────────────
# Installation (systemd bevorzugt, sonst Cron)
is_installed_systemd(){ [[ -f "$SERVICE_FILE" && -f "$TIMER_FILE" ]]; }
is_installed_cron(){ crontab -l 2>/dev/null | grep -qF "$CRON_MARKER" || false; }
is_installed(){ is_installed_systemd || is_installed_cron; }

ensure_env_file() {
  if [[ ! -f "$ENV_FILE" ]]; then
    cat > "$ENV_FILE" <<EOF
# ${SERVICE} environment
# Anpassbar: Textfile-Directory des Node Exporters (leer = Autodetect)
#OSUPDATER_OUTPUT_DIR=/var/lib/node_exporter
# Schwelle für Compliance
PATCH_THRESHOLD=${PATCH_THRESHOLD}
# Timeout für apt-get update in Sekunden
APT_UPDATE_TIMEOUT=${APT_UPDATE_TIMEOUT}
EOF
    chmod 0644 "$ENV_FILE"
  fi
}

install_systemd() {
  [[ $EUID -eq 0 ]] || { echo "ERROR: --install benötigt root." >&2; exit 1; }
  mkdir -p "$(dirname "$INSTALL_PATH")"
  cp -f "$SELF" "$INSTALL_PATH"
  chmod 0755 "$INSTALL_PATH"
  ensure_env_file

  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=OS Updates Prometheus Exporter (textfile)
After=network-online.target

[Service]
Type=oneshot
EnvironmentFile=-${ENV_FILE}
ExecStart=${INSTALL_PATH} --oneshot
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7

[Install]
WantedBy=multi-user.target
EOF

  cat > "$TIMER_FILE" <<EOF
[Unit]
Description=Run ${SERVICE} periodically

[Timer]
OnBootSec=5m
OnUnitActiveSec=${INSTALL_INTERVAL}
RandomizedDelaySec=5m
Persistent=true

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now "${SERVICE}.timer"
  log "installed systemd service+timer (${INSTALL_INTERVAL})"

  # Ensure textfile dir exists and owner fits exporter
  local outdir="$(detect_textfile_dir)"; mkdir -p "$outdir"
  local _m _u _g; IFS=: read -r _m _u _g <<<"$(detect_exporter_identity)"
  chown "$_u:$_g" "$outdir" 2>/dev/null || true
  chmod 0750 "$outdir" 2>/dev/null || true
}

install_cron() {
  [[ $EUID -eq 0 ]] || { echo "ERROR: --install benötigt root." >&2; exit 1; }
  mkdir -p "$(dirname "$INSTALL_PATH")"
  cp -f "$SELF" "$INSTALL_PATH"
  chmod 0755 "$INSTALL_PATH"
  ensure_env_file

  local cron_line
  # Cron kennt keine "1h" Syntax → mappe grob: 1h=hourly, 30m=*/30
  case "$INSTALL_INTERVAL" in
    30m|30min|30mins) cron_line="*/30 * * * * ${INSTALL_PATH} --oneshot >/dev/null 2>&1 ${CRON_MARKER}" ;;
    15m|15min|15mins) cron_line="*/15 * * * * ${INSTALL_PATH} --oneshot >/dev/null 2>&1 ${CRON_MARKER}" ;;
    5m|5min|5mins)    cron_line="*/5 * * * * ${INSTALL_PATH} --oneshot >/dev/null 2>&1 ${CRON_MARKER}" ;;
    * )               cron_line="0 * * * * ${INSTALL_PATH} --oneshot >/dev/null 2>&1 ${CRON_MARKER}" ;; # ~1h
  esac

  local tmpc; tmpc="$(mktemp)"
  crontab -l 2>/dev/null | grep -vF "$CRON_MARKER" > "$tmpc" || true
  printf '%s\n' "$cron_line" >> "$tmpc"
  crontab "$tmpc"; rm -f "$tmpc"
  log "installed cron job (${INSTALL_INTERVAL})"

  local outdir="$(detect_textfile_dir)"; mkdir -p "$outdir"
  local _m _u _g; IFS=: read -r _m _u _g <<<"$(detect_exporter_identity)"
  chown "$_u:$_g" "$outdir" 2>/dev/null || true
  chmod 0750 "$outdir" 2>/dev/null || true
}

uninstall_all() {
  if have_systemd && is_installed_systemd; then
    systemctl disable --now "${SERVICE}.timer" || true
    rm -f "$SERVICE_FILE" "$TIMER_FILE"
    systemctl daemon-reload || true
    log "removed systemd units"
  fi
  if is_installed_cron; then
    local tmpc; tmpc="$(mktemp)"
    crontab -l 2>/dev/null | grep -vF "$CRON_MARKER" > "$tmpc" || true
    crontab "$tmpc" || true
    rm -f "$tmpc"
    log "removed cron entry"
  fi
  log "uninstall done"
}

print_status() {
  if have_systemd; then
    systemctl list-timers --all | grep -E "${SERVICE}\.timer" || true
    systemctl status "${SERVICE}.timer" --no-pager || true
  fi
  if crontab -l 2>/dev/null | grep -qF "$CRON_MARKER"; then
    echo "Cron:"
    crontab -l | grep -F "$CRON_MARKER" || true
  fi
  echo "Script path: $INSTALL_PATH (present: $(test -x "$INSTALL_PATH" && echo yes || echo no))"
  echo "Env file:    $ENV_FILE (present: $(test -f "$ENV_FILE" && echo yes || echo no))"
  echo "Output dir:  $(detect_textfile_dir)"
}

usage(){
  cat <<EOF
Usage: $0 [--install|--uninstall|--status|--oneshot]

  --install     Installiert sich selbst (bevorzugt systemd, sonst Cron)
  --uninstall   Entfernt Timer/Service bzw. Cron-Eintrag
  --status      Zeigt Installationsstatus
  --oneshot     Führt nur den Collector-Lauf aus (für Timer/Cron)

Ohne Parameter:
  - Wenn noch nicht installiert und root: auto-Install (systemd oder Cron)
  - Andernfalls: einmaliger Collector-Lauf

Konfiguration via ${ENV_FILE} oder ENV Variablen:
  PATCH_THRESHOLD (Default ${PATCH_THRESHOLD})
  OSUPDATER_OUTPUT_DIR (leer = Autodetect)
  APT_UPDATE_TIMEOUT (Default ${APT_UPDATE_TIMEOUT})
  INSTALL_INTERVAL (Default ${INSTALL_INTERVAL})
EOF
}

main(){
  # ENV Datei laden, falls vorhanden (nur für Laufzeit-Config; Installbestimmung bleibt davon unberührt)
  [[ -f "$ENV_FILE" ]] && . "$ENV_FILE" || true
  OUTPUT_DIR="$(detect_textfile_dir)"

  case "${1-}" in
    --install) if have_systemd; then install_systemd; else install_cron; fi; exit 0 ;;
    --uninstall) uninstall_all; exit 0 ;;
    --status) print_status; exit 0 ;;
    --oneshot) run_collector; exit 0 ;;
    "") 
        if ! is_installed && [[ $EUID -eq 0 ]]; then
          if have_systemd; then install_systemd; else install_cron; fi
          exit 0
        fi
        run_collector
        ;;
    *) usage; exit 2 ;;
  esac
}

main "$@"
