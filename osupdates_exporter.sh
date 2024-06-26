#!/bin/bash

# Function to process APT
process_apt() {
    echo "Starting apt-get update..."
    apt-get update -qq
    updates=$(apt list --upgradable 2>/dev/null | grep -v -e "^Listing..." -e "^Auflistung" -e "^$" | grep -e "/.*\[" | wc -l)
    echo "apt updates counted: $updates"

    {
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
    } > /var/lib/node_exporter/os_updates.prom
}

# Function to process YUM
process_yum() {
    echo "Starting yum makecache..."
    yum makecache -q
    updates=$(yum check-update | grep -E '^[a-zA-Z0-9]' | grep -v -e 'Obsoleting' -e 'Security' -e 'No packages marked for update' -e 'Last' | wc -l)
    echo "yum updates counted: $updates"

    {
        echo "# HELP os_pending_updates Number of pending updates"
        echo "# TYPE os_pending_updates gauge"
        echo "os_pending_updates $updates"
        if [ "$updates" -gt 0 ]; then
            updates_list=$(yum check-update | grep -E '^[a-zA-Z0-9]' | grep -v -e 'Obsoleting' -e 'Security' -e 'No packages marked for update' -e 'Last' | awk '{print $1}' | tr '\n' ',' | sed 's/,$//')
        else
            updates_list="No updates available"
        fi
        echo "# HELP os_pending_updates_list List of pending updates"
        echo "# TYPE os_pending_updates_list gauge"
        echo "os_pending_updates_list{updates=\"$updates_list\"} 0"
    } > /var/lib/node_exporter/os_updates.prom
}

# Function to process DNF
process_dnf() {
    echo "Starting dnf makecache..."
    dnf makecache -q
    updates=$(dnf check-update | grep -E '^[a-zA-Z0-9]' | grep -v -e 'Security' -e 'Last metadata' -e 'Last' | wc -l)
    echo "dnf updates counted: $updates"

    {
        echo "# HELP os_pending_updates Number of pending updates"
        echo "# TYPE os_pending_updates gauge"
        echo "os_pending_updates $updates"
        if [ "$updates" -gt 0 ]; then
            updates_list=$(dnf check-update | grep -E '^[a-zA-Z0-9]' | grep -v -e 'Security' -e 'Last metadata' -e 'Last' | awk '{print $1}' | tr '\n' ',' | sed 's/,$//')
        else
            updates_list="No updates available"
        fi
        echo "# HELP os_pending_updates_list List of pending updates"
        echo "# TYPE os_pending_updates_list gauge"
        echo "os_pending_updates_list{updates=\"$updates_list\"} 0"
    } > /var/lib/node_exporter/os_updates.prom
}

# Detect operating system and package manager
if command -v apt &> /dev/null; then
    process_apt
elif command -v yum &> /dev/null; then
    process_yum
elif command -v dnf &> /dev/null; then
    process_dnf
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
    echo "# HELP os_pending_updates_list List of pending updates" >> /var/lib/node_export and "# TYPE os_pending_updates_list gauge" >> /var_lib/node_exporter/os_updates.prom
    echo "os_pending_updates_list{updates=\"No updates available\"} 0" >> /var_lib/node_exporter/os_updates.prom
fi
