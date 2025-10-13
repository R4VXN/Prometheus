# os-updates-exporter (v0.5)

I built a minimal **Prometheus textfile exporter** that writes `os_updates.prom` for Node Exporter / Grafana Alloy. It inspects OS package updates and repo health across **APT/DNF/YUM/ZYPPER**, exposes compact metrics, and ships with a one-shot **systemd** unit plus a **timer**. A daily self-updater pulls the latest GitHub Release asset so hosts stay current without config management.

## Highlights
- **Zero-runtime agent**: oneshot binary invoked by a timer (no long-lived daemon).
- **Package managers**: apt, dnf, yum, zypper.
- **Holds-aware**: ignores version-locked/held packages.
- **Security vs. bugfix split** (where the PM supports it).
- **Repo health**: reachability and metadata age.
- **OS signals**: reboot-required, EOL flag (embedded map), maintenance-window flag.
- **Housekeeping**: legacy cleanup on install; safe atomic writes; textfile dir auto-detection.
- **Self-update**: daily via GitHub `releases/latest` asset (no jq required).

## Quick start (host)
```bash
# install
curl -fsSL https://raw.githubusercontent.com/R4VXN/Prometheus/main/install_os_updates_exporter.sh -o install_os_updates_exporter.sh
sudo bash install_os_updates_exporter.sh

# status & first run verification
systemctl status os-updates-exporter.timer
/usr/local/bin/os-updates-exporter --version
ls -l /var/lib/node_exporter/os_updates.prom
journalctl -u os-updates-exporter -n50 --no-pager
```

> The installer enables two timers: `os-updates-exporter.timer` (collector) and `os-updates-exporter-update.timer` (daily self-update). The binary is downloaded from **GitHub Releases** using `releases/latest` with architecture-specific tarballs (e.g. `os-updates-exporter_Linux_amd64.tar.gz`).

## Configuration
Environment file: **`/etc/os-updates-exporter.env`**

Exporter env:
- `TEXTFILE_DIR` (default `/var/lib/node_exporter`) — where `os_updates.prom` is written
- `PATCH_THRESHOLD` (default `3`) — compliance threshold
- `REPO_DETAILS` (`0|1`) — include per-repo up/down metrics (increase cardinality)
- `TOPN_PACKAGES` (default `0`) — emit per-package labels for the first N upgradable packages
- `MW_START`, `MW_END` (HHMM) — maintenance window flag
- `REPO_HEAD_TIMEOUT` (default `5s`) — HTTP HEAD timeout for repo checks
- `PKGMGR_TIMEOUT` (default `90s`) — shell command timeout for package manager calls

Installer/timer env:
- `INSTALL_INTERVAL` (default `15m`) — cadence for the collector timer

After changing the env file:
```bash
sudo systemctl daemon-reload
sudo systemctl restart os-updates-exporter.timer
```

## Metrics (selection)
- `os_pending_updates{manager, type="security|bugfix"}`
- `os_pending_reboots`
- `os_updates_compliant` (<= threshold)
- `os_updates_info{manager, exporter, output_dir, os, os_version, threshold}`
- `os_updates_last_run_timestamp_seconds`
- `os_updates_run_duration_seconds`
- `os_updates_scrape_success`
- `os_updates_file_age_seconds`
- `os_updates_in_maintenance_window`
- `os_repo_unreachable_total{manager}`
- `os_repo_total{manager}`
- `os_repo_metadata_age_seconds{manager}`
- `os_pending_update_info{manager, package}` (if enabled via `TOPN_PACKAGES`)
- `os_release_eol` (embedded EOL map)
- `os_fs_free_bytes{mount="/var|/boot"}`

## Service names
- Collector: `os-updates-exporter.service` + `os-updates-exporter.timer`
- Self-update: `os-updates-exporter-update.service` + `os-updates-exporter-update.timer`

## Uninstall / cleanup
```bash
sudo systemctl disable --now os-updates-exporter.timer os-updates-exporter-update.timer
sudo rm -f /etc/systemd/system/os-updates-exporter*.service /etc/systemd/system/os-updates-exporter*.timer
sudo systemctl daemon-reload
sudo rm -f /usr/local/bin/os-updates-exporter /etc/os-updates-exporter.env
```

## Compatibility
Linux hosts with **apt/dnf/yum/zypper**. Designed for Prometheus **node_exporter** (textfile collector) and **Grafana Alloy** equivalents.

## Security notes
Oneshot unit with hardening: `NoNewPrivileges`, `ProtectSystem=full`, `PrivateTmp`. Metrics file written atomically as `0640` into the textfile directory.

## Versioning & Releases
The daily updater fetches the **latest** GitHub Release asset. To roll out a new version, publish a new release and make sure it is not marked as pre-release.
