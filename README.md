<center><img width="845" alt="arc_loader" src="https://github.com/AuxXxilium/AuxXxilium/assets/67025065/ef975a36-9f3e-4cfb-813c-402db69611e7"></center>

# These are Utilities for usage with Arc Loader

### Root login to DSM

```
sudo -i
```

---

### Arc Benchmark

This needs to run as 'root' (Usage at own risk):

```
curl -fsSL https://bench.auxxxilium.tech -o /root/bench.sh && chmod +x /root/bench.sh && /root/bench.sh
```

---

### Active Backup for Business (Active Backup for Microsoft 365, Active Backup for Google Workspace) activation

This needs to run as 'root' (Usage at own risk):

```
curl -fsSL https://abb.auxxxilium.tech -o /root/activation && chmod +x /root/activation && /root/activation
```

---

### App Installer (for Apps with online verification)

- Advanced Media Extensions 4.0.0-4025
- Surveillance Video Extension 1.0.0-0015

This needs to run as 'root' (Usage at own risk):

```
curl -fsSL https://appinstaller.auxxxilium.tech -o /root/appinstaller && chmod +x /root/appinstaller
/root/appinstaller --install-app (Choose the app in App Store and press install while the script is running)
```

---

### App Downloader (for Apps with online verification)

- Advanced Media Extensions 4.0.0-4025
- Surveillance Video Extension 1.0.0-0015

This needs to run as 'root' (Usage at own risk):

```
curl -fsSL https://appdownloader.auxxxilium.tech -o /root/appdownloader && chmod +x /root/appdownloader
/root/appdownloader --install-ame (Force install and activate Advanced Media Extensions)
/root/appdownloader --install-sve (Force install and activate Surveillance Video Extension)
```

---

### Forcemount

- Create a storage pool on a disk type that DSM does not support (e.g., Hyper-V virtual disks)

This needs to run as 'root' while DSM Installation screen is shown (Usage at own risk):

```
curl -fsSL https://forcemount.auxxxilium.tech -o /root/forcemount && chmod +x /root/forcemount
/root/forcemount --createpool --auto      # Create a new pool
/root/forcemount --install --md /dev/md2  # install the tool, automatically mounts the pool on system startup
```

---

### Arc PVE Installer / Updater

- Thanks to [@And-rix](https://github.com/And-rix)

This needs to run in PVE Shell (Usage at own risk):

Installer:
```
curl -fsSL https://pveinstall.auxxxilium.tech -o /root/arc-install.sh && chmod +x /root/arc-install.sh && /root/arc-install.sh
```

Updater:
```
curl -fsSL https://pveupdate.auxxxilium.tech -o /root/arc-update.sh && chmod +x /root/arc-update.sh && /root/arc-update.sh
```
