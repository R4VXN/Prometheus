#!/bin/bash

# Funktion zur Verarbeitung von APT
process_apt() {
    apt-get update -qq
    updates=$(apt list --upgradable 2>/dev/null | grep -v "Listing..." | wc -l)
    echo "# HELP os_pending_updates Anzahl der ausstehenden Updates"
    echo "# TYPE os_pending_updates gauge"
    echo "os_pending_updates $updates"
    if [ "$updates" -gt 0 ]; then
        updates_list=$(apt list --upgradable 2>/dev/null | grep -v "Listing..." | awk -F/ '{print $1}' | tr '\n' ',' | sed 's/,$//')
    else
        updates_list="Keine Updates verfügbar"
    fi
    echo "# HELP os_pending_updates_list Liste der ausstehenden Updates"
    echo "# TYPE os_pending_updates_list gauge"
    echo "os_pending_updates_list{updates=\"$updates_list\"} 0"
}

# Funktion zur Verarbeitung von YUM
process_yum() {
    yum makecache -q
    updates=$(yum check-update | grep -E '^[a-zA-Z0-9]' | grep -v 'Obsoleting' | grep -v 'Security' | wc -l)
    updates=$((updates / 3)) # Da yum check-update 3 Zeilen pro Update ausgibt
    echo "# HELP os_pending_updates Anzahl der ausstehenden Updates"
    echo "# TYPE os_pending_updates gauge"
    echo "os_pending_updates $updates"
    if [ "$updates" -gt 0 ]; then
        updates_list=$(yum check-update | grep -E '^[a-zA-Z0-9]' | grep -v 'Obsoleting' | grep -v 'Security' | awk '{print $1}' | tr '\n' ',' | sed 's/,$//')
    else
        updates_list="Keine Updates verfügbar"
    fi
    echo "# HELP os_pending_updates_list Liste der ausstehenden Updates"
    echo "# TYPE os_pending_updates_list gauge"
    echo "os_pending_updates_list{updates=\"$updates_list\"} 0"
}

# Funktion zur Verarbeitung von DNF
process_dnf() {
    dnf makecache -q
    updates=$(dnf check-update | grep -E '^[a-zA-Z0-9]' | grep -v "^Last metadata" | grep -v 'Security' | wc -l)
    updates=$((updates / 3)) # Da dnf check-update 3 Zeilen pro Update ausgibt
    echo "# HELP os_pending_updates Anzahl der ausstehenden Updates"
    echo "# TYPE os_pending_updates gauge"
    echo "os_pending_updates $updates"
    if [ "$updates" -gt 0 ]; then
        updates_list=$(dnf check-update | grep -E '^[a-zA-Z0-9]' | grep -v "^Last metadata" | grep -v 'Security' | awk '{print $1}' | tr '\n' ',' | sed 's/,$//')
    else
        updates_list="Keine Updates verfügbar"
    fi
    echo "# HELP os_pending_updates_list Liste der ausstehenden Updates"
    echo "# TYPE os_pending_updates_list gauge"
    echo "os_pending_updates_list{updates=\"$updates_list\"} 0"
}

# Betriebssystem und Paketmanager erkennen
if command -v apt &> /dev/null; then
    process_apt > /var/lib/node_exporter/os_updates.prom
elif command -v yum &> /dev/null; then
    process_yum > /var/lib/node_exporter/os_updates.prom
elif command -v dnf &> /dev/null; then
    process_dnf > /var/lib/node_exporter/os_updates.prom
else
    echo "Kein unterstützter Paketmanager gefunden." >&2
    exit 1
fi

# Sicherstellen, dass die Metriken auf 0 gesetzt werden, wenn keine Updates gefunden wurden
if ! grep -q "os_pending_updates" /var/lib/node_exporter/os_updates.prom; then
    echo "# HELP os_pending_updates Anzahl der ausstehenden Updates" >> /var/lib/node_exporter/os_updates.prom
    echo "# TYPE os_pending_updates gauge" >> /var/lib/node_exporter/os_updates.prom
    echo "os_pending_updates 0" >> /var/lib/node_exporter/os_updates.prom
fi

if ! grep -q "os_pending_updates_list" /var/lib/node_exporter/os_updates.prom; then
    echo "# HELP os_pending_updates_list Liste der ausstehenden Updates" >> /var/lib/node_exporter/os_updates.prom
    echo "# TYPE os_pending_updates_list gauge" >> /var/lib/node_exporter/os_updates.prom
    echo "os_pending_updates_list{updates=\"Keine Updates verfügbar\"} 0" >> /var/lib/node_exporter/os_updates.prom
fi

