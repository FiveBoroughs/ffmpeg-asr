# ffmpeg-asr

Adaptive stream re-encoder with automatic hardware acceleration detection.

## What it does

Wraps ffmpeg to transcode streams with hardware acceleration. On first run, probes your hardware to find working encoders and caches the optimal settings. Automatically handles:

- Hardware encoder selection (NVENC, VAAPI, QSV, VideoToolbox)
- 10-bit input conversion for H264 encoders
- Passthrough for 4K, HDR, and unsupported formats

## Usage

```bash
./ffmpeg-smart.sh -i "stream_url" -user_agent "User-Agent"
```

Outputs MPEG-TS to stdout.

### Options

| Option | Default | Description |
|--------|---------|-------------|
| `-i` | (required) | Input URL or file |
| `-user_agent` | | User agent for HTTP streams |
| `-accel` | auto | Hardware acceleration: `qsv`, `vaapi`, `nvenc`, `videotoolbox`, `v4l2m2m`, `software` |
| `-vc` | auto | Output codec: `h264` (faster) or `hevc` (smaller files) |
| `-10bit` | auto | Enable 10-bit encoding (for capable hardware) |
| `-hdr` | auto | Enable HDR re-encoding (requires 10-bit HEVC) |
| `--recache` | | Force re-probe encoder capabilities |

### Examples

```bash
# Basic usage (auto-detect accel, H264 output)
./ffmpeg-smart.sh -i "http://stream.url/live.m3u8" -user_agent "Mozilla/5.0"

# Force HEVC output (smaller files, slower)
./ffmpeg-smart.sh -i "stream_url" -user_agent "UA" -vc hevc

# Enable 10-bit encoding on capable hardware
./ffmpeg-smart.sh -i "stream_url" -user_agent "UA" -vc hevc -10bit

# Force specific acceleration
./ffmpeg-smart.sh -i "stream_url" -user_agent "UA" -accel vaapi
```

## Encoding settings

- **Video bitrate**: Scales quadratically with resolution (8 Mbps base at 1080p, 2 Mbps floor)
- **Audio bitrate**: 64 kbps per channel (128k stereo, 384k 5.1, 512k 7.1)
- **B-frames**: Enabled (2) for better compression
- **GOP**: 1 second (matches source framerate)

## Passthrough

Video is passed through (not re-encoded) when:
- Resolution is 4K or higher
- 10-bit content when hardware can't encode 10-bit
- HDR content when hardware can't encode HDR (requires 10-bit HEVC)

## 10-bit and HDR handling

The script automatically handles 10-bit and HDR input based on hardware capabilities:

| Input | Output Codec | Hardware Support | Result |
|-------|--------------|------------------|--------|
| 10-bit | H264 | any | Convert to 8-bit (H264 can't encode 10-bit) |
| 10-bit | HEVC | 10-bit encode | Keep 10-bit |
| 10-bit | HEVC | no 10-bit encode | Passthrough |
| HDR | HEVC | 10-bit encode | Re-encode with HDR metadata preserved |
| HDR | HEVC | no 10-bit encode | Passthrough |
| HDR | H264 | any | Passthrough (H264 doesn't support HDR) |

Conversion uses hardware scalers (`scale_cuda`, `scale_vaapi`, etc.) to stay on GPU.

## Capability caching

On first run, the script:
1. Downloads a 10-bit HEVC probe sample (~4MB from Jellyfin)
2. Tests each encoder with real hwaccel decode/encode pipeline
3. Caches results to `.capabilities.cache`

```
.capabilities.cache   # Cached encoder test results
probe-sample.mkv      # Jellyfin 10-bit HEVC demo clip
```

Example cache:
```bash
HW_FINGERPRINT='0x10de:0x2216;nvidia:NVIDIA_GeForce_RTX_3080;'
BEST_ACCEL='nvenc'
BEST_CODEC='h264'
SUPPORTS_10BIT_DECODE='true'
SUPPORTS_10BIT_ENCODE='true'
ENCODERS='h264_nvenc=1;hevc_nvenc=1;hevc_nvenc_10bit=1;libx264=1;libx265=1;'
```

The cache auto-invalidates when GPU hardware changes. Use `--recache` to force re-probe.

### Docker usage

The cache lives in the script directory, so just mount the whole folder:

```yaml
volumes:
  - /path/to/ffmpeg-smart:/app
```

## Hardware detection order

1. macOS → VideoToolbox
2. `/dev/nvidia0` exists → NVENC
3. Intel GPU → VAAPI
4. AMD GPU → VAAPI
5. V4L2 M2M device (ARM boards) → V4L2M2M
6. DRI device exists → VAAPI
7. Nothing found → software

## Benchmarking

### Quick benchmark (tests ffmpeg-smart.sh)

```bash
./benchmark-live.sh [duration] [mode]
./benchmark-live.sh 15 live    # Test against live streams
./benchmark-live.sh 15 local   # Test against local sample files
./benchmark-live.sh 15 all     # Both (default)
```

### Full encoder benchmark

```bash
./benchmark-accel.sh [duration] [runs]
./benchmark-accel.sh 30 3  # 30 seconds per test, 3 runs each
```

Downloads Jellyfin demo files and benchmarks all encoder combinations.

### Benchmark results

Tested on Intel integrated graphics (1080p HEVC source):

| Accel | H264 | HEVC |
|-------|------|------|
| vaapi | 5.8x | 2.9x |
| qsv | 5.5x | 3.6x |
| software | 1.4x | 0.4x |

**H264 is ~2x faster than HEVC** across all accelerators. This is why `-vc h264` is the default.

For live streams, anything above 1x realtime is sufficient. Software HEVC (0.4x) cannot keep up with realtime.
