#!/usr/bin/env bash
set -euo pipefail

# Config
OUTPUT_DIR="/var/lib/node_exporter"
OUTPUT_FILE="${OUTPUT_DIR}/os_updates.prom"
TMP_FILE="$(mktemp "${OUTPUT_DIR}/.os_updates.prom.XXXXXX")"

# Cleanup on exit
cleanup() {
    rm -f "$TMP_FILE"
}
trap cleanup EXIT

# Ensure output dir exists
mkdir -p "$OUTPUT_DIR"

# Escape function für Prometheus-Labels
escape_label() {
    local s="$1"
    s="${s//\\/\\\\}"      # Backslashes
    s="${s//\"/\\\"}"      # Anführungszeichen
    s="${s//$'\n'/\\n}"    # Newlines
    printf '%s' "$s"
}

# Ermittelt gelockte Pakete je Manager
get_locked() {
    local mgr="$1"
    case "$mgr" in
        apt)
            apt-mark showhold 2>/dev/null || true
            ;;
        dnf)
            # benötigt dnf-plugins-core
            dnf versionlock list 2>/dev/null | awk '/^[0-9]/{print $2}' || true
            ;;
        yum)
            # yum-plugin-versionlock
            yum versionlock list 2>/dev/null | awk '/^[0-9]/{print $2}' || true
            ;;
        zypper)
            # zypper locks list
            zypper locks 2>/dev/null | awk -F' ' '/^  \(/ {print $2}' | sed 's/[()]//g' || true
            ;;
        *)
            # unbekannt
            ;;
    esac
}

# Generic update checker
# args: <manager> <update-cmd...>
check_updates() {
    local mgr="$1"; shift
    local cmd=( "$@" )
    local raw pkgs locked filtered count

    # Updates abrufen
    raw="$("${cmd[@]}" 2>/dev/null || echo '')"

    # Alle Paketnamen extrahieren (eines pro Zeile)
    mapfile -t pkgs < <(printf '%s\n' "$raw" | grep -E '^[[:alnum:]]' || true)
    # Gelockte Pakete ermitteln
    mapfile -t locked < <(get_locked "$mgr")
    # Herausfiltern
    if [ "${#locked[@]}" -gt 0 ]; then
        for lp in "${locked[@]}"; do
            pkgs=( "${pkgs[@]/$lp}" )
        done
    fi

    # Anzahl und Metriken schreiben
    count="${#pkgs[@]}"
    {
        echo "# HELP os_pending_updates Number of pending updates"
        echo "# TYPE os_pending_updates gauge"
        echo "os_pending_updates{manager=\"${mgr}\"} ${count}"
        echo "# HELP os_pending_update_info Per-package pending update info"
        echo "# TYPE os_pending_update_info gauge"
        for pkg in "${pkgs[@]}"; do
            [ -z "$pkg" ] && continue
            pkg_esc="$(escape_label "$pkg")"
            echo "os_pending_update_info{manager=\"${mgr}\",package=\"${pkg_esc}\"} 1"
        done
    } >> "$TMP_FILE"
}

# Detect distro und ausführen
if command -v apt-get &>/dev/null; then
    apt-get update -qq
    check_updates apt \
        bash -c "apt list --upgradable 2>/dev/null | grep -vE '^(Listing|Auflistung|$)' | awk -F'/' '{print \$1}'"
elif command -v dnf &>/dev/null; then
    dnf makecache -q
    check_updates dnf \
        bash -c "dnf check-update 2>/dev/null | grep -E '^[[:alnum:]]' | awk '{print \$1}'"
elif command -v yum &>/dev/null; then
    yum makecache -q
    check_updates yum \
        bash -c "yum check-update 2>/dev/null | grep -E '^[[:alnum:]]' | awk '{print \$1}'"
elif command -v zypper &>/dev/null; then
    zypper refresh -s >/dev/null
    check_updates zypper \
        bash -c "zypper list-updates | awk '/v |v /{print \$3}'"
else
    echo "ERROR: Kein unterstützter Paketmanager gefunden." >&2
    exit 1
fi

# Atomischer Austausch
mv "$TMP_FILE" "$OUTPUT_FILE"
