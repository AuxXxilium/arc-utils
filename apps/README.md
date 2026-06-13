# Video Compute Runtime for Synology DSM 7.2+ - Hardware Acceleration Edition (Replacement for ffmpeg and synocli-video-driver)

## Package Overview

Video Compute Runtime (vcrt) is a unified video and compute stack for Synology NAS systems running DSM 7.2 or later. It bundles FFmpeg 8.1 with full hardware acceleration support, Intel video drivers, OpenCL, Vulkan, and diagnostic tools.

**Maintainer:** AuxXxilium  
**Architecture:** x64-7.2 (apollolake, broadwell, denverton and compatible)  
**Build System:** spksrc (SynoCommunity framework)

![Video Compute Runtime](dsm-screen.png)

## Hardware Acceleration Features

### NVIDIA GPU Support
- **NVENC** - Hardware-accelerated H.264/HEVC encoding (up to 8K)
- **NVDEC** - Hardware-accelerated video decoding
- **CUVID** - CUDA Video Decode API
- **CUDA** - GPU compute acceleration
- **Requirements:** NVIDIA GPU with driver 550.54.14+ (supports API 12.2)
- **Performance:** 50-300x realtime encoding speeds on modern GPUs

### Intel Quick Sync Video (QSV)
- **oneVPL / libvpl** - Intel Video Processing Library (modern replacement for libmfx)
- **Intel MediaSDK** - Legacy QSV support
- **H.264/HEVC** encoding and decoding
- **VP9** encoding support
- **Hardware scaling** and color conversion
- **Requirements:** Intel CPU with integrated graphics (6th gen or newer recommended) or Arc GPU
- **Performance:** 20-70x realtime encoding speeds

### VAAPI (Intel & AMD)
- **VA-API** - Video Acceleration API
- **Intel** - iGPU and Arc GPU support via intel-media-driver and intel-vaapi-driver
- **AMD** - iGPU and Radeon GPU support
- **DRM/libdrm** - Direct Rendering Manager integration
- **Hardware formats:** NV12, P010, YUV420P

### Cross-Platform Acceleration
- **Vulkan** - Cross-platform GPU compute (Intel, NVIDIA, AMD) via MESA and Khronos loader
- **OpenCL** - GPU compute for filters and processing via ocl-icd (Intel Compute Runtime bundled; NVIDIA and AMD runtimes loaded automatically if driver is present)

## Included Tools

- **ffmpeg** - Full-featured video/audio encoder and transcoder
- **ffprobe** - Media file analyzer
- **vainfo** - VAAPI driver and profile information
- **clinfo** - OpenCL platform and device information
- **vulkaninfo** - Vulkan instance and device information
- **lsgpu** - GPU device listing

## Video Codecs & Formats

### Encoders
- **H.264/AVC** - Software (x264) + Hardware (NVENC, QSV, VAAPI)
- **H.265/HEVC** - Software (x265) + Hardware (NVENC, QSV, VAAPI)
- **AV1** - Software (libaom, libsvtav1) + Hardware (AMF on AMD)
- **VVC/H.266** - Software (vvenc)
- **VP8/VP9** - Software (libvpx) + Hardware (QSV for VP9)
- **H.264 OpenH264** - Cisco OpenH264 software encoder
- **JPEG 2000** - Software (libopenjpeg)
- **WebP** - Software (libwebp)
- **Theora** - Software (libtheora)
- **ProRes** - Professional codec support
- **MPEG-2/4** - Legacy codec support

### Decoders
- **Software:** AV1 (dav1d), all common formats
- **Hardware-accelerated:**
  - NVIDIA NVDEC/CUVID: H.264, HEVC, VP8, VP9, MPEG-2/4, VC-1, AV1
  - Intel QSV: H.264, HEVC, VP9, MPEG-2, VC-1, AV1
  - VAAPI (Intel): H.264, HEVC, VP8, VP9, MPEG-2, AV1
  - VAAPI (AMD): H.264, HEVC, VP9, AV1 (via Mesa radeonsi/VCN)
  - AMF (AMD): H.264, HEVC

### Audio Codecs
- **AAC** - Native + libfdk-aac (high-quality)
- **MP3** - LAME encoder + Shine (fixed-point MP3)
- **Opus** - Modern low-latency codec
- **FLAC** - Lossless compression
- **AC3/EAC3** - Dolby Digital
- **Vorbis** - Open-source codec
- **AMR-NB/WB** - Voice codecs (opencore-amr)
- **MP2** - TWolame encoder
- **Speex** - Voice codec
- **LC3** - Bluetooth LE Audio codec
- **Codec2** - Ultra low bitrate voice codec

### Streaming Protocols
- **SRT** - Secure Reliable Transport (low-latency streaming)
- **RIST** - Reliable Internet Stream Transport
- **RabbitMQ** - AMQP messaging integration
- **ZMQ** - ZeroMQ messaging integration
- **DASH** - Dynamic Adaptive Streaming over HTTP (via libxml2)

### Compute & GPU Runtime

- **Intel Compute Runtime (NEO)** - OpenCL 3.0 implementation for Intel Gen9+ iGPUs and Arc GPUs
- **OpenCL (ocl-icd)** - Khronos OpenCL ICD loader, dispatches to installed platforms
- **Intel Level Zero** - Low-level GPU interface used by Compute Runtime
- **Intel Graphics Compiler (IGC)** - LLVM-based shader/kernel compiler for Intel GPUs
- **Mesa (radeonsi + ANV + RADV)** - OpenCL and Vulkan drivers for Intel and AMD GPUs
- **Vulkan Loader** - Khronos Vulkan ICD loader (Khronos-Vulkan-Loader)
- **Vulkan Tools** - vulkaninfo and other diagnostic utilities
- **shaderc** - GLSL/HLSL to SPIR-V shader compiler (used by FFmpeg Vulkan pipeline)
- **Intel oneVPL / libvpl** - Modern video processing library for Intel Quick Sync
- **Intel VPL Tools** - oneVPL diagnostic and benchmark utilities
- **Intel GPU Tools (lsgpu)** - GPU device listing and diagnostics

### Filters & Processing
- **libplacebo** - GPU-accelerated video processing and tone mapping (GCC 12+)
- **libzimg (zscale)** - High-quality scaling and color conversion
- **librubberband** - Time-stretching and pitch-shifting
- **libvmaf** - Netflix VMAF video quality metric
- **libass** - Advanced SubStation Alpha subtitle rendering
- **frei0r** - Video effects plugin collection
- **chromaprint** - Audio fingerprinting
- **libcaca** - Color ASCII art output

## Known Limitations

1. **NVIDIA Support**
   - Requires manual NVIDIA community driver installation
   - Driver must be 550.54.14+

2. **Intel QSV**
   - Requires recent Intel CPU (6th gen+)
   - Some older Synology models have limited QSV features

3. **Intel VAAPI**
   - Requires Intel GPU with supported VAAPI driver (intel-media-driver or intel-vaapi-driver)
   - intel-media-driver supports Broadwell (5th gen) and newer; older CPUs require intel-vaapi-driver
   - Some Synology models with older Atom CPUs have limited VAAPI feature support

4. **AMD VAAPI**
   - Limited support on Synology hardware
   - Requires proper AMD GPU driver installation

[Download](#download)

---

# More Information

## Download

- **Xpenology Apps:** Add ```https://apps.xpenology.tech``` to your DSM Package Center -> Settings -> Package Sources

## Support & Resources

- **GitHub:** https://github.com/AuxXxilium
- **Website:** https://auxxxilium.tech
- **Issues:** Report bugs via [Discord (Community)](https://community.xpenology.tech)

## License

FFmpeg is licensed under the **GNU GPL v3** (with optional codecs enabled).

This package includes:
- **GPL libraries:** x264, x265, fdk-aac
- **LGPL libraries:** Most other components
- **Non-free:** NVIDIA NVENC/CUVID support
