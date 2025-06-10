
# Instructions for Modifying Node Exporter Configuration and Creating Custom Metrics for yum dnf and apt Update metrics

**Note:**

*APT Packetmanager only filters for the English and German language.*

*With DNF & Yum the OS language does not matter*


*In the readme is not always the latest script please have a look at the osupdates_exporter.sh*

## Objective

Modify the configuration of Node Exporter to add the `--collector.textfile.directory` parameter and create custom metrics (`os_pending_updates` and `os_pending_updates_list`) collected from text files in a specific directory.

## Modifying the ExecStart Line with sed

You can directly edit the Node Exporter configuration file using the `sed` command to add the path for the text file directory. This approach is particularly useful if you want to automate this change or apply it across multiple systems simultaneously.

1. Open a terminal session on the server where Node Exporter is installed.

2. Back up the existing systemd service file before making changes:

    ```bash
    sudo cp /etc/systemd/system/node_exporter.service /etc/systemd/system/node_exporter.service.bak
    ```

3. Use `sed` to modify the ExecStart line. This command searches for the line containing `ExecStart=/usr/local/bin/node_exporter` and adds the `--collector.textfile.directory=/var/lib/node_exporter` parameter:

    ```bash
    sudo sed -i 's|ExecStart=/usr/local/bin/node_exporter|ExecStart=/usr/local/bin/node_exporter --collector.textfile.directory=/var/lib/node_exporter|' /etc/systemd/system/node_exporter.service
    ```

4. Reload the systemd daemon to recognize the changes:

    ```bash
    sudo systemctl daemon-reload
    ```

5. Restart Node Exporter to apply the configuration changes:

    ```bash
    sudo systemctl restart node_exporter
    ```

6. Check the status of the Node Exporter service to ensure it is running without errors:

    ```bash
    sudo systemctl status node_exporter
    ```

## Creating a Script for Custom Metrics

Create a script named `osupdates_exporter.sh` in the `/opt/scripts/` directory with the following content:

```bash
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





```

## Making the Script Executable

Ensure the script is executable:

```bash
sudo chmod +x /opt/scripts/osupdates_exporter.sh
```

## Setting Up a Cron Job

Set up a cron job to run the script regularly to update the metrics.

1. Open the crontab configuration:

    ```bash
    crontab -e
    ```

2. Add the following line to run the script every 5 minutes:

    ```bash
    */5 * * * * /opt/scripts/osupdates_exporter.sh
    ```

## Verifying the New Configuration

Create a test text file to ensure Node Exporter collects the metrics correctly.

1. Create a test text file:

    ```bash
    echo '# HELP test_metric This is a test metric' > /var/lib/node_exporter/test.prom
    echo '# TYPE test_metric gauge' >> /var/lib/node_exporter/test.prom
    echo 'test_metric 42' >> /var/lib/node_exporter/test.prom
    ```

2. Then check if the metric is available in Prometheus by browsing the metrics page of Node Exporter:

    ```bash
    curl http://localhost:9100/metrics | grep osupdates_exporter.sh
    ```

With these steps, you should be able to successfully modify the Node Exporter configuration and use custom metrics.
