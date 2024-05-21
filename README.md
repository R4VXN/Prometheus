Anleitung zur Änderung der Node Exporter Konfiguration und Erstellung benutzerdefinierter Metriken
Ziel
Ändern der Konfiguration des Node Exporters, um den Parameter --collector.textfile.directory hinzuzufügen und benutzerdefinierte Metriken (os_pending_updates und os_pending_updates_list) zu erstellen, die aus Textdateien in einem bestimmten Verzeichnis gesammelt werden.

Ändern der ExecStart-Zeile mit sed
Sie können die Konfigurationsdatei des Node Exporters direkt mit dem sed-Befehl bearbeiten, um den Pfad für das Textdateiverzeichnis hinzuzufügen. Dieser Ansatz ist besonders nützlich, wenn Sie diese Änderung automatisieren oder auf mehreren Systemen gleichzeitig durchführen möchten.

Öffnen Sie eine Terminal-Sitzung auf dem Server, auf dem der Node Exporter installiert ist.

Sichern Sie die bestehende Systemd-Dienstdatei, bevor Sie Änderungen vornehmen:

bash
Copy code
sudo cp /etc/systemd/system/node_exporter.service /etc/systemd/system/node_exporter.service.bak
Verwenden Sie sed, um die ExecStart-Zeile zu ändern. Dieser Befehl sucht nach der Zeile, die ExecStart=/usr/local/bin/node_exporter enthält, und fügt den Parameter --collector.textfile.directory=/var/lib/node_exporter hinzu:

bash
Copy code
sudo sed -i 's|ExecStart=/usr/local/bin/node_exporter|ExecStart=/usr/local/bin/node_exporter --collector.textfile.directory=/var/lib/node_exporter|' /etc/systemd/system/node_exporter.service
Laden Sie den Systemd-Daemon neu, um die Änderungen zu erkennen:

bash
Copy code
sudo systemctl daemon-reload
Starten Sie den Node Exporter neu, um die Konfigurationsänderungen zu übernehmen:

bash
Copy code
sudo systemctl restart node_exporter
Überprüfen Sie den Status des Node Exporter Dienstes, um sicherzustellen, dass er ohne Fehler läuft:

bash
Copy code
sudo systemctl status node_exporter

bash
Copy code
sudo systemctl status node_exporter
7. Skript zur Erstellung benutzerdefinierter Metriken erstellen
Erstellen Sie ein Skript namens osupdates_exporter.sh im Verzeichnis /opt/scripts/ mit folgendem Inhalt:

bash
Copy code
#!/bin/bash

# Funktion zur Verarbeitung von APT
process_apt() {
    apt-get update -qq
    updates=$(apt list --upgradable 2>/dev/null | grep -v "Listing..." | wc -l)
    echo "# HELP os_pending_updates Anzahl der ausstehenden Updates"
    echo "# TYPE os_pending_updates gauge"
    echo "os_pending_updates $updates"
    if [ "$updates" -gt 0 ]; then
        updates_list=$(apt list --upgradable 2>/dev/null | grep -v "Listing..." | awk -F/ '{print $1}' | tr '\n' ',')
        updates_list=${updates_list%,}  # Entfernt das letzte Komma
    else
        updates_list="Keine Updates verfügbar"
    fi
    echo "# HELP os_pending_updates_list Liste der ausstehenden Updates"
    echo "# TYPE os_pending_updates_list gauge"
    echo "os_pending_updates_list{updates=\"$updates_list\"} 1"
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
8. Skript ausführbar machen
Stellen Sie sicher, dass das Skript ausführbar ist:

bash
Copy code
sudo chmod +x /opt/scripts/osupdates_exporter.sh
9. Cron-Job einrichten
Richten Sie einen Cron-Job ein, der das Skript regelmäßig ausführt, um die Metriken zu aktualisieren.

Öffnen Sie die Crontab-Konfiguration:

bash
Copy code
crontab -e
Fügen Sie folgende Zeile hinzu, um das Skript alle 5 Minuten auszuführen:

bash
Copy code
*/5 * * * * /opt/scripts/osupdates_exporter.sh
10. Überprüfen der neuen Konfiguration
Erstellen Sie eine Test-Textdatei, um sicherzustellen, dass der Node Exporter die Metriken korrekt sammelt.

Erstellen Sie eine Test-Textdatei:

bash
Copy code
echo '# HELP test_metric Dies ist eine Testmetrik' > /var/lib/node_exporter/test.prom
echo '# TYPE test_metric gauge' >> /var/lib/node_exporter/test.prom
echo 'test_metric 42' >> /var/lib/node_exporter/test.prom
Überprüfen Sie dann, ob die Metrik in Prometheus verfügbar ist, indem Sie die Metrikseite des Node Exporters durchsuchen:

bash
Copy code
curl http://localhost:9100/metrics | grep test_metric
Mit diesen Schritten sollten Sie die Konfiguration des Node Exporters erfolgreich ändern und die benutzerdefinierten Metriken nutzen können.

Copy code
wo ist der teil mit sed
ChatGPT
Entschuldigung für das Versehen! Hier ist der Abschnitt, der erklärt, wie Sie die ExecStart-Zeile der Node Exporter Konfiguration mit sed ändern können:
