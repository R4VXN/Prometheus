
# Instructions for Modifying Node Exporter Configuration and Creating Custom Metrics for yum dnf and apt Update metrics

**Note:**

*APT Packetmanager only filters for the English and German language.*

*With DNF & Yum the OS language does not matter*

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
