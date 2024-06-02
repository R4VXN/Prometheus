
# Anleitung zur Änderung der Node Exporter Konfiguration und Erstellung benutzerdefinierter Metriken

## Ziel

Ändern der Konfiguration des Node Exporters, um den Parameter `--collector.textfile.directory` hinzuzufügen und benutzerdefinierte Metriken (`os_pending_updates` und `os_pending_updates_list`) zu erstellen, die aus Textdateien in einem bestimmten Verzeichnis gesammelt werden.

## Ändern der ExecStart-Zeile mit sed

Sie können die Konfigurationsdatei des Node Exporters direkt mit dem `sed`-Befehl bearbeiten, um den Pfad für das Textdateiverzeichnis hinzuzufügen. Dieser Ansatz ist besonders nützlich, wenn Sie diese Änderung automatisieren oder auf mehreren Systemen gleichzeitig durchführen möchten.

1. Öffnen Sie eine Terminal-Sitzung auf dem Server, auf dem der Node Exporter installiert ist.

2. Sichern Sie die bestehende Systemd-Dienstdatei, bevor Sie Änderungen vornehmen:

    ```bash
    sudo cp /etc/systemd/system/node_exporter.service /etc/systemd/system/node_exporter.service.bak
    ```

3. Verwenden Sie `sed`, um die ExecStart-Zeile zu ändern. Dieser Befehl sucht nach der Zeile, die `ExecStart=/usr/local/bin/node_exporter` enthält, und fügt den Parameter `--collector.textfile.directory=/var/lib/node_exporter` hinzu:

    ```bash
    sudo sed -i 's|ExecStart=/usr/local/bin/node_exporter|ExecStart=/usr/local/bin/node_exporter --collector.textfile.directory=/var/lib/node_exporter|' /etc/systemd/system/node_exporter.service
    ```

4. Laden Sie den Systemd-Daemon neu, um die Änderungen zu erkennen:

    ```bash
    sudo systemctl daemon-reload
    ```

5. Starten Sie den Node Exporter neu, um die Konfigurationsänderungen zu übernehmen:

    ```bash
    sudo systemctl restart node_exporter
    ```

6. Überprüfen Sie den Status des Node Exporter Dienstes, um sicherzustellen, dass er ohne Fehler läuft:

    ```bash
    sudo systemctl status node_exporter
    ```

## Skript zur Erstellung benutzerdefinierter Metriken erstellen

Erstellen Sie ein Skript namens `osupdates_exporter.sh` im Verzeichnis `/opt/scripts/` mit folgendem Inhalt:

```bash
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

```

## Skript ausführbar machen

Stellen Sie sicher, dass das Skript ausführbar ist:

```bash
sudo chmod +x /opt/scripts/osupdates_exporter.sh
```

## Cron-Job einrichten

Richten Sie einen Cron-Job ein, der das Skript regelmäßig ausführt, um die Metriken zu aktualisieren.

1. Öffnen Sie die Crontab-Konfiguration:

    ```bash
    crontab -e
    ```

2. Fügen Sie folgende Zeile hinzu, um das Skript alle 5 Minuten auszuführen:

    ```bash
    */5 * * * * /opt/scripts/osupdates_exporter.sh
    ```

## Überprüfen der neuen Konfiguration

Erstellen Sie eine Test-Textdatei, um sicherzustellen, dass der Node Exporter die Metriken korrekt sammelt.

1. Erstellen Sie eine Test-Textdatei:

    ```bash
    echo '# HELP test_metric Dies ist eine Testmetrik' > /var/lib/node_exporter/test.prom
    echo '# TYPE test_metric gauge' >> /var/lib/node_exporter/test.prom
    echo 'test_metric 42' >> /var/lib/node_exporter/test.prom
    ```

2. Überprüfen Sie dann, ob die Metrik in Prometheus verfügbar ist, indem Sie die Metrikseite des Node Exporters durchsuchen:

    ```bash
    curl http://localhost:9100/metrics | grep test_metric
    ```

Mit diesen Schritten sollten Sie die Konfiguration des Node Exporters erfolgreich ändern und die benutzerdefinierten Metriken nutzen können.
