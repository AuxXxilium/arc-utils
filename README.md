<center><img width="845" alt="arc_loader" src="https://github.com/AuxXxilium/arc/raw/page/docs/arc_loader.png?raw=true"></center>

# These are Utilities for usage with Arc Loader / Xpenology

## Root login to DSM

```
sudo -i
```

---

## AppInstaller

- Thanks to [@ohyeah521](https://github.com/ohyeah521) for the help

Install & patch or activate the following apps on your Arc or Xpenology NAS:
- Active Backup for Business (3.1.0-24967)
- Active Backup for Business G Suite (2.2.6-14205)
- Active Backup for Business Office 365 (2.6.1-14214)
- Advanced Media Extensions (4.0.0-4025)
- MailPlus Server (3.3.0-21523, 3.4.0-21566, 3.4.1-21569)
- Surveillance Station (9.2.4-11880, 9.2.5-11979, 9.3.0-12139)
- Surveillance Video Extension (1.1.0-0101)
- AI Console (1.2.0-0480, 1.2.1-0483)

Patch the following apps on your Arc or Xpenology NAS (if installed):
- MailPlus Server (3.3.0-21523)
- MailPlus Server (3.4.0-21566)
- MailPlus Server (3.4.1-21569)
- Surveillance Station (9.2.4-11880) only Default and DVA1622 (OpenVINO)
- Surveillance Station (9.2.5-11979) only Default and DVA3221
- Surveillance Station (9.3.0-12139) only Default

Surveillance Station and MailPlus Server are patched in place from embedded
byte-patch manifests (no downloads); the original files are backed up first and
can be restored from the app's submenu.

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
- Storage read speed test using hdparm for quick disk performance estimation
- Storage I/O performance test using fio across multiple read/write scenarios
- Hardware transcoding performance test using [VCRT](./apps) (if iGPU/GPU is available)
- CPU performance test using local cpu benchmark solution

This needs to run as 'root' (Usage at own risk):

```
curl -fsSL https://bench.xpenology.tech -o /root/bench.sh && chmod +x /root/bench.sh
```
```
/root/bench.sh
```

---

## VCRT (Video Compute Runtime)

Complete audio/video transcoding and compute solution with hardware acceleration support for Synology DSM.

Features:
- NVIDIA NVENC/NVDEC hardware acceleration
- Intel Quick Sync Video (QSV)
- VAAPI support
- Vulkan and OpenCL acceleration
- High-performance video encoding/decoding for transcoding and streaming

For build instructions and installation details, see the [Apps](./apps).

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
