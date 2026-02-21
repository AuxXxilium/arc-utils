<center><img width="845" alt="arc_loader" src="https://github.com/AuxXxilium/arc/raw/page/docs/arc_loader.png?raw=true"></center>

# These are Utilities for usage with Arc Loader / Xpenology

## Root login to DSM

```
sudo -i
```

---

## AppInstaller

- Thanks to [@ohyeah521](https://github.com/ohyeah521) for the help

Install & patch or activate the following apps on your Arc or Xpenology NAS (if not installed):
- Active Backup for Business (3.1.0-24967)
- Active Backup for Business G Suite (2.2.6-14205)
- Active Backup for Business Office 365 (2.6.1-14214)
- Advanced Media Extensions (4.0.0-4025)
- MailPlus Server (3.4.1-21569)
- Surveillance Station (9.2.3-11755)
- Surveillance Video Extension (1.0.0-0015)
- Virtual Machine Manager (2.7.0-12229)

Activate the following apps on your Arc or Xpenology NAS (if installed):
- Active Backup for Business (3.1.0-24967)
- Active Backup for Business G Suite (2.2.6-14205)
- Active Backup for Business Office 365 (2.6.1-14214)

Patch the following apps on your Arc or Xpenology NAS (if installed):
- MailPlus Server (3.3.0-21523)
- MailPlus Server (3.4.0-21566)
- MailPlus Server (3.4.1-21569)
- Surveillance Station (9.2.0-11289)
- Surveillance Station (9.2.3-11755)
- Surveillance Station (9.2.4-11880) only Default and DVA1622 for now
- Virtual Machine Manager (2.7.0-12229)

Patch (if installed):
- FFmpeg7 to allow full iGPU usage

How-to use:
1. Download the appinstaller script to your Arc or Xpenology NAS.
2. Execute the script to install or activate the app.
3. Follow the prompts to complete the process.

This needs to run as 'root' (Usage at own risk):

```
curl -fsSL https://appinstaller.xpenology.tech -o /root/appinstaller && chmod +x /root/appinstaller
```
```
/root/appinstaller
```

---

## Arc Benchmark

How-to use:
1. Download the benchmark script to your Xpenology NAS.
2. Execute the script to run the benchmark.
3. Follow the prompts to complete the benchmark process.

Benchmark:
- Storage (hdparm) is close to estimated performance
- iGPU (ffmpeg7 transcoding) if installed
- CPU (Geekbench 6)

This needs to run as 'root' (Usage at own risk):

```
curl -fsSL https://bench.xpenology.tech -o /root/bench.sh && chmod +x /root/bench.sh
```
```
/root/bench.sh
```

---

## Arc PVE Toolkit

- Thanks to [@And-rix](https://github.com/And-rix) for this solution

How-to use:
1. Download the toolkit script to your Proxmox VE (PVE) server.
2. Execute the script to install or update Arc Loader on your PVE server.
3. Follow the prompts to complete the installation or update process.

This needs to run in PVE Shell (Usage at own risk):

Toolkit:
```
curl -fsSL https://pvetoolkit.xpenology.tech -o /root/arc-toolkit.sh && chmod +x /root/arc-toolkit.sh
```
```
/root/arc-toolkit.sh
```
