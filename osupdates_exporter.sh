#!/usr/bin/env bash
set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# Config (überschreibbar via ENV)
: "${OSUPDATER_OUTPUT_DIR:=/var/lib/node_exporter}"
: "${PATCH_THRESHOLD:=3}"
OUTPUT_DIR="${OSUPDATER_OUTPUT_DIR%/}"
OUTPUT_FILE="${OUTPUT_DIR}/os_updates.prom"
TMP_FILE="$(mktemp "${OUTPUT_DIR}/.os_updates.prom.XXXXXX")"
# ──────────────────────────────────────────────────────────────────────────────

cleanup() {
    rm -f "$TMP_FILE"
}
trap cleanup EXIT

# Detect Alloy vs Node Exporter
if systemctl list-units --type=service | grep -q -E 'alloy(\.service)?$'; then
    MODE="alloy"
    EXPORTER_USER="alloy"
    EXPORTER_GROUP="alloy"
elif command -v node_exporter &>/dev/null    || systemctl list-units --type=service | grep -q -E 'node_exporter(\.service)?$'; then
    MODE="node_exporter"
    EXPORTER_USER="node_exporter"
    EXPORTER_GROUP="node_exporter"
else
    MODE="generic"
    EXPORTER_USER="$(id -un)"
    EXPORTER_GROUP="$(id -gn)"
fi

mkdir -p "$OUTPUT_DIR"
chown "$EXPORTER_USER":"$EXPORTER_GROUP" "$OUTPUT_DIR"
chmod 0750 "$OUTPUT_DIR"

escape_label() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    printf '%s' "$s"
}

get_locked() {
    local mgr="$1"
    case "$mgr" in
        apt)    apt-mark showhold 2>/dev/null || true ;;
        dnf)    dnf versionlock list 2>/dev/null | awk '/^[0-9]/{print $2}' || true ;;
        yum)    yum versionlock list 2>/dev/null | awk '/^[0-9]/{print $2}' || true ;;
        zypper) zypper locks 2>/dev/null | awk -F' ' '/^\s*\(.*\)/{gsub(/[()]/,"",$2);print $2}' || true ;;
        *)      return ;;
    esac
}

check_updates() {
    local mgr="$1"; shift
    local cmd=( "$@" )
    local raw pkgs locked count pkg pkg_esc

    raw="$("${cmd[@]}" 2>/dev/null || echo '')"
    mapfile -t pkgs < <(printf '%s
' "$raw" | grep -E '^[[:alnum:]]' || true)
    mapfile -t locked < <(get_locked "$mgr")
    for lp in "${locked[@]:-}"; do
        pkgs=( "${pkgs[@]/$lp}" )
    done

    count=${#pkgs[@]}

    # Security vs Bugfix (only for dnf & yum)
    local sec_all=() sec_crit=()
    if [[ "$mgr" =~ ^(dnf|yum)$ ]]; then
        mapfile -t sec_all < <( "$mgr" updateinfo list security 2>/dev/null | awk '{print $2}' || true )
        mapfile -t sec_crit < <( "$mgr" updateinfo list security --sec-severity=Critical 2>/dev/null | awk '{print $2}' || true )
    fi
    local sec_count=${#sec_all[@]}
    local crit_count=${#sec_crit[@]}
    local bugfix_count=$(( count - sec_count ))

    # Write metrics
    {
        printf '# HELP os_pending_updates Total pending updates by type
'
        printf '# TYPE os_pending_updates gauge
'
        printf 'os_pending_updates{manager="%s",type="security"} %d
' "$mgr" "$sec_count"
        printf 'os_pending_updates{manager="%s",type="bugfix"} %d
'   "$mgr" "$bugfix_count"
        printf '# HELP os_pending_cves_total Number of critical CVEs pending
'
        printf '# TYPE os_pending_cves_total gauge
'
        printf 'os_pending_cves_total{severity="Critical"} %d
' "$crit_count"
        printf '# HELP os_pending_reboots Whether a reboot is pending
'
        printf '# TYPE os_pending_reboots gauge
'
        printf 'os_pending_reboots %d
' "$(test -f /var/run/reboot-required && echo 1 || echo 0)"
        printf '# HELP os_updates_compliant Whether update count <= threshold
'
        printf '# TYPE os_updates_compliant gauge
'
        printf 'os_updates_compliant %d
' $(( count <= PATCH_THRESHOLD ? 1 : 0 ))
        printf '# HELP os_pending_update_info Detailed per-package info
'
        printf '# TYPE os_pending_update_info gauge
'
    } >> "$TMP_FILE"

    for pkg in "${pkgs[@]:-}"; do
        [[ -z "$pkg" ]] && continue
        pkg_esc="$(escape_label "$pkg")"
        printf 'os_pending_update_info{manager="%s",package="%s"} 1
' "$mgr" "$pkg_esc"
    done >> "$TMP_FILE"
}

# Distro detection and checks
if command -v apt-get &>/dev/null; then
    apt-get update -qq
    check_updates apt bash -c "apt list --upgradable 2>/dev/null | grep -vE '^(Listing|Auflist|$)' | awk -F'/' '{print \$1}'"
elif command -v dnf &>/dev/null; then
    dnf makecache -q
    check_updates dnf bash -c "dnf check-update 2>/dev/null | grep -E '^[[:alnum:]]' | awk '{print \$1}'"
elif command -v yum &>/dev/null; then
    yum makecache -q
    check_updates yum bash -c "yum check-update 2>/dev/null | grep -E '^[[:alnum:]]' | awk '{print \$1}'"
elif command -v zypper &>/dev/null; then
    zypper refresh -s >/dev/null
    check_updates zypper bash -c "zypper list-updates | awk '/v |v /{print \$3}'"
else
    echo "ERROR: Kein unterstützter Paketmanager gefunden." >&2
    exit 1
fi

mv "$TMP_FILE" "$OUTPUT_FILE"
