<center><img width="845" alt="arc_loader" src="https://github.com/AuxXxilium/arc/raw/page/docs/arc_loader.png?raw=true"></center>

# These are Utilities for usage with Arc Loader / Xpenology

## Root login to DSM

```
sudo -i
```

---

## Arc Benchmark

How-to use:
1. Download the benchmark script to your Xpenology NAS.
2. Execute the script to run the benchmark.
3. Follow the prompts to complete the benchmark process.

This needs to run as 'root' (Usage at own risk):

```
curl -fsSL https://bench.auxxxilium.tech -o /root/bench.sh && chmod +x /root/bench.sh
```
```
/root/bench.sh
```

---

## App Installer

Install and activate the following apps on your Arc or Xpenology NAS:
- Active Backup for Business (3.0.0-24638)
- Active Backup for Business G Suite (2.2.5-14029)
- Active Backup for Business Office 365 (2.6.0-14071)
- Advanced Media Extensions (4.0.0-4025)
- Surveillance Video Extension (1.0.0-0015)

Patch the following apps on your Arc or Xpenology NAS:
- Mail-Plus Server (3.3.0-21523)
- Surveillance Station (9.2.0-11289 / 9.2.3-11755)
- Virtual Machine Manager (2.7.0-12229)

How-to use:
1. Download the appinstaller script to your Arc or Xpenology NAS.
2. Execute the script with the command below to install and activate the app.

This needs to run as 'root' (Usage at own risk):

```
curl -fsSL https://appinstaller.auxxxilium.tech -o /root/appinstaller && chmod +x /root/appinstaller
```
### Active Backup for Business:
```
/root/appinstaller --install-abb
```
### Active Backup for Business GSuite:
```
/root/appinstaller --install-abb-gsuite
```
### Active Backup for Business Office 365:
```
/root/appinstaller --install-abb-office365
```
### Advanced Media Extensions:
```
/root/appinstaller --install-ame
```
### Surveillance Video Extension:
```
/root/appinstaller --install-sve
```
### Mail-Plus Server:
```
/root/appinstaller --patch-mp
```
### Surveillance Station:
```
/root/appinstaller --patch-ss
```
### Virtual Machine Manager:
```
/root/appinstaller --patch-vmm
```

---

## Forcemount

- Create a storage pool on a disk type that DSM does not support (e.g., Hyper-V virtual disks)

How-to use:
1. Download the forcemount script to your Xpenology NAS.
2. Execute the script with the `--createpool --auto` option to create a new storage pool.
3. Execute the script with the `--install --md /dev/md2` option to install the tool, which automatically mounts the pool on system startup.

This needs to run as 'root' while DSM Installation screen is shown (Usage at own risk):

```
curl -fsSL https://forcemount.auxxxilium.tech -o /root/forcemount && chmod +x /root/forcemount
```
```
/root/forcemount --createpool --auto
```
```
/root/forcemount --install --md /dev/md2
```

---

## Arc PVE Installer / Updater

- Thanks to [@And-rix](https://github.com/And-rix)

How-to use:
1. Download the installer or updater script to your Proxmox VE (PVE) server.
2. Execute the script to install or update Arc Loader on your PVE server.
3. Follow the prompts to complete the installation or update process.

This needs to run in PVE Shell (Usage at own risk):

Installer:
```
curl -fsSL https://pveinstall.auxxxilium.tech -o /root/arc-install.sh && chmod +x /root/arc-install.sh
```
```
/root/arc-install.sh
```

Updater:
```
curl -fsSL https://pveupdate.auxxxilium.tech -o /root/arc-update.sh && chmod +x /root/arc-update.sh
```
```
/root/arc-update.sh
```
