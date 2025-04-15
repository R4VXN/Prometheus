#!/bin/bash
set -euo pipefail

# Ziel-Datei für Prometheus-Metriken
output_file="/var/lib/node_exporter/os_updates.prom"
tmp_output=$(mktemp)

# Aufräumfunktion zum Entfernen des temporären Files
cleanup() {
    rm -f "$tmp_output"
}
trap cleanup EXIT

# Funktion zum Schreiben der Metriken in ein temporäres File und anschließendes Verschieben
write_metrics() {
    local updates_count="$1"
    local updates_list="$2"

    {
        echo "# HELP os_pending_updates Number of pending updates"
        echo "# TYPE os_pending_updates gauge"
        echo "os_pending_updates $updates_count"
        echo "# HELP os_pending_updates_list List of pending updates"
        echo "# TYPE os_pending_updates_list gauge"
        echo "os_pending_updates_list{updates=\"$updates_list\"} 0"
    } > "$tmp_output"

    mv "$tmp_output" "$output_file"
}

process_apt() {
    echo "Processing APT..."
    # Führe Update durch und breche ab, wenn ein Fehler auftritt
    apt-get update -qq || { echo "apt-get update failed"; exit 1; }

    # Speichern der Ausgabe, um sie mehrfach zu verwenden
    local apt_output
    apt_output=$(apt list --upgradable 2>/dev/null | grep -v -e "^Listing..." -e "^Auflistung" -e "^$")
    local count
    count=$(echo "$apt_output" | grep -E "/.*\[" | wc -l)
    echo "APT updates counted: $count"

    local list
    if [ "$count" -gt 0 ]; then
        list=$(echo "$apt_output" | grep -E "/.*\[" | awk -F/ '{print $1}' | paste -sd "," -)
    else
        list="No updates available"
    fi
    write_metrics "$count" "$list"
}

process_yum() {
    echo "Processing YUM..."
    yum makecache -q || { echo "yum makecache failed"; exit 1; }

    local yum_output
    yum_output=$(yum check-update 2>/dev/null)
    local count
    count=$(echo "$yum_output" | grep -E '^[a-zA-Z0-9]' | grep -v -e 'Obsoleting' -e 'Security' -e 'No packages marked for update' -e 'Last' | wc -l)
    echo "YUM updates counted: $count"

    local list
    if [ "$count" -gt 0 ]; then
        list=$(echo "$yum_output" | grep -E '^[a-zA-Z0-9]' | grep -v -e 'Obsoleting' -e 'Security' -e 'No packages marked for update' -e 'Last' | awk '{print $1}' | paste -sd "," -)
    else
        list="No updates available"
    fi
    write_metrics "$count" "$list"
}

process_dnf() {
    echo "Processing DNF..."
    dnf makecache -q || { echo "dnf makecache failed"; exit 1; }

    local dnf_output
    dnf_output=$(dnf check-update 2>/dev/null)
    local count
    count=$(echo "$dnf_output" | grep -E '^[a-zA-Z0-9]' | grep -v -e 'Security' -e 'Last metadata' -e 'Last' | wc -l)
    echo "DNF updates counted: $count"

    local list
    if [ "$count" -gt 0 ]; then
        list=$(echo "$dnf_output" | grep -E '^[a-zA-Z0-9]' | grep -v -e 'Security' -e 'Last metadata' -e 'Last' | awk '{print $1}' | paste -sd "," -)
    else
        list="No updates available"
    fi
    write_metrics "$count" "$list"
}

# Ermitteln, welcher Paketmanager vorhanden ist, und den entsprechenden Prozess ausführen
if command -v apt-get &> /dev/null; then
    process_apt
elif command -v yum &> /dev/null; then
    process_yum
elif command -v dnf &> /dev/null; then
    process_dnf
else
    echo "No supported package manager found." >&2
    exit 1
fi
