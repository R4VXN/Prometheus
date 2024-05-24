#!/bin/bash

# Function to process APT
process_apt() {
    apt-get update -qq
    updates=$(apt list --upgradable 2>/dev/null | grep -v -e "^Listing..." -e "^Auflistung" -e "^$" | grep -e "/.*\[" | wc -l)
    echo "# HELP os_pending_updates Number of pending updates"
    echo "# TYPE os_pending_updates gauge"
    echo "os_pending_updates $updates"
    if [ "$updates" -gt 0 ]; then
        updates_list=$(apt list --upgradable 2>/dev/null | grep -v -e "^Listing..." -e "^Auflistung" -e "^$" | grep -e "/.*\[" | awk -F/ '{print $1}' | tr '\n' ',' | sed 's/,$//')
    else
        updates_list="No updates available"
    fi
    echo "# HELP os_pending_updates_list List of pending updates"
    echo "# TYPE os_pending_updates_list gauge"
    echo "os_pending_updates_list{updates=\"$updates_list\"} 0"
}

# Function to process YUM
process_yum() {
    yum makecache -q
    updates=$(yum check-update | grep -E '^[a-zA-Z0-9]' | grep -v 'Obsoleting' | grep -v 'Security' | wc -l)
    updates=$((updates / 3)) # Since yum check-update outputs 3 lines per update
    echo "# HELP os_pending_updates Number of pending updates"
    echo "# TYPE os_pending_updates gauge"
    echo "os_pending_updates $updates"
    if [ "$updates" -gt 0 ]; then
        updates_list=$(yum check-update | grep -E '^[a-zA-Z0-9]' | grep -v 'Obsoleting' | grep -v 'Security' | awk '{print $1}' | tr '\n' ',' | sed 's/,$//')
    else
        updates_list="No updates available"
    fi
    echo "# HELP os_pending_updates_list List of pending updates"
    echo "# TYPE os_pending_updates_list gauge"
    echo "os_pending_updates_list{updates=\"$updates_list\"} 0"
}

# Function to process DNF
process_dnf() {
    dnf makecache -q
    updates=$(dnf check-update | grep -E '^[a-zA-Z0-9]' | grep -v "^Last metadata" | grep -v 'Security' | wc -l)
    updates=$((updates / 3)) # Since dnf check-update outputs 3 lines per update
    echo "# HELP os_pending_updates Number of pending updates"
    echo "# TYPE os_pending_updates gauge"
    echo "os_pending_updates $updates"
    if [ "$updates" -gt 0 ]; then
        updates_list=$(dnf check-update | grep -E '^[a-zA-Z0-9]' | grep -v "^Last metadata" | grep -v 'Security' | awk '{print $1}' | tr '\n' ',' | sed 's/,$//')
    else
        updates_list="No updates available"
    fi
    echo "# HELP os_pending_updates_list List of pending updates"
    echo "# TYPE os_pending_updates_list gauge"
    echo "os_pending_updates_list{updates=\"$updates_list\"} 0"
}

# Detect operating system and package manager
if command -v apt &> /dev/null; then
    process_apt > /var/lib/node_exporter/os_updates.prom
elif command -v yum &> /dev/null; then
    process_yum > /var/lib/node_exporter/os_updates.prom
elif command -v dnf &> /dev/null; then
    process_dnf > /var/lib/node_exporter/os_updates.prom
else
    echo "No supported package manager found." >&2
    exit 1
fi

# Ensure metrics are set to 0 if no updates are found
if ! grep -q "os_pending_updates" /var/lib/node_exporter/os_updates.prom; then
    echo "# HELP os_pending_updates Number of pending updates" >> /var/lib/node_exporter/os_updates.prom
    echo "# TYPE os_pending_updates gauge" >> /var/lib/node_exporter/os_updates.prom
    echo "os_pending_updates 0" >> /var/lib/node_exporter/os_updates.prom
fi

if ! grep -q "os_pending_updates_list" /var/lib/node_exporter/os_updates.prom; then
    echo "# HELP os_pending_updates_list List of pending updates" >> /var/lib/node_exporter/os_updates.prom
    echo "# TYPE os_pending_updates_list gauge" >> /var/lib/node_exporter/os_updates.prom
    echo "os_pending_updates_list{updates=\"No updates available\"} 0" >> /var/lib/node_exporter/os_updates.prom
fi
