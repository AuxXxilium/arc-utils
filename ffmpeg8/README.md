# FFmpeg 8.1 for Synology DSM 7 - Hardware Acceleration Edition

## Package Overview

FFmpeg 8.1 compiled with comprehensive hardware acceleration support for Synology NAS systems running DSM 7. This custom build enables GPU-accelerated video encoding and decoding across NVIDIA, Intel, and AMD hardware platforms.

**Version:** 8.1-1  
**Maintainer:** AuxXxilium  
**Architecture:** x64-7.2 (apollolake, broadwell, denverton and compatible)  
**Build System:** spksrc (SynoCommunity framework)

---

## Hardware Acceleration Features

### NVIDIA GPU Support
- **NVENC** - Hardware-accelerated H.264/HEVC encoding (up to 8K)
- **NVDEC** - Hardware-accelerated video decoding
- **CUVID** - CUDA Video Decode API
- **CUDA** - GPU compute acceleration
- **Requirements:** NVIDIA GPU with driver 550.54.14+ (supports API 12.2)
- **Performance:** 50-100x realtime encoding speeds on modern GPUs

### Intel Quick Sync Video (QSV)
- **libmfx** - Intel Media SDK integration
- **H.264/HEVC** encoding and decoding
- **VP9** encoding support
- **Hardware scaling** and color conversion
- **Requirements:** Intel CPU with integrated graphics (6th gen or newer recommended)
- **Performance:** 20-40x realtime encoding speeds

### VAAPI (Intel & AMD)
- **VA-API** - Video Acceleration API
- **Intel** - iGPU and Arc GPU support
- **AMD** - Radeon GPU support
- **DRM/libdrm** - Direct Rendering Manager integration
- **Hardware formats:** NV12, P010, YUV420P

### Cross-Platform Acceleration
- **Vulkan** - Cross-platform GPU compute (Intel, NVIDIA, AMD)
- **OpenCL** - GPU compute for filters and processing

---

## Video Codecs & Formats

### Encoders
- **H.264/AVC** - Software (x264) + Hardware (NVENC, QSV, VAAPI)
- **H.265/HEVC** - Software (x265) + Hardware (NVENC, QSV, VAAPI)
- **VP8/VP9** - Software (libvpx) + Hardware (QSV for VP9)
- **AV1** - Software (libaom, libsvtav1)
- **ProRes** - Professional codec support
- **MPEG-2/4** - Legacy codec support

### Decoders
- **Hardware-accelerated:**
  - NVIDIA: H.264, HEVC, VP8, VP9, MPEG-2/4, VC-1
  - Intel QSV: H.264, HEVC, VP9, MPEG-2, VC-1
  - VAAPI: H.264, HEVC, VP8, VP9, MPEG-2

### Audio Codecs
- **AAC** - Native + libfdk-aac (high-quality)
- **MP3** - LAME encoder
- **Opus** - Modern low-latency codec
- **FLAC** - Lossless compression
- **AC3/EAC3** - Dolby Digital
- **Vorbis** - Open-source codec
- **AMR-NB/WB** - Voice codecs

---

## Known Limitations

1. **NVIDIA Support**
   - Requires manual NVIDIA driver installation
   - Driver must be 550.54.14+ for nv-codec-headers 12.2.72.0
   - Not supported on official Synology units (custom builds only)

2. **Intel QSV**
   - Requires recent Intel CPU (6th gen+)
   - Some older Synology models have limited QSV features
   - Media SDK must be properly configured

3. **AMD VAAPI**
   - Limited support on Synology hardware
   - Requires proper AMD GPU driver installation
   - Performance varies by GPU model

---

## Support & Resources

- **GitHub:** https://github.com/AuxXxilium
- **Website:** https://auxxxilium.tech
- **Issues:** Report bugs via Discord (Community)

---

## License

FFmpeg is licensed under the **GNU GPL v3** (with optional non-free codecs enabled).

This package includes:
- **GPL libraries:** x264, x265, fdk-aac (with --enable-nonfree)
- **LGPL libraries:** Most other components
- **Non-free:** NVIDIA NVENC/CUVID support

---

## Build Information

**Compiler:** GCC 12.2.0  
**Toolchain:** spksrc x86_64-pc-linux-gnu  
**Build Date:** 2026-05-03  
**spksrc Version:** th0ma7/spksrc:ffmpeg8 branch  
**Custom Modifications:**
- NVIDIA nv-codec-headers 12.2.72.0 (driver 550+ compatible)
- Intel Media SDK integration
- Optimized build flags (-O3, LTO)
- MAINTAINER customization

---

## Changelog

### Version 8.1-1
- Initial release based on FFmpeg 8.1
- NVIDIA NVENC support (API 12.2, driver 550+)
- Intel Quick Sync Video (libmfx)
- VAAPI support for Intel/AMD
- Vulkan and OpenCL acceleration
- Comprehensive codec support
- Built with GCC 12.2.0 optimizations
