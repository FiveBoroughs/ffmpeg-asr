# ffmpeg-asr

Adaptive stream re-encoder with automatic hardware acceleration detection.

## What it does

Wraps ffmpeg to transcode streams with hardware acceleration when available. Auto-detects your GPU and picks the right encoder. Passes through content that shouldn't be re-encoded (4K, HDR, 10-bit by default).

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
| `-vc` | `h264` | Output codec: `h264` (faster) or `hevc` (smaller files) |
| `-10bit` | off | Enable 10-bit encoding (for capable hardware) |

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
- 10-bit content (unless `-10bit` flag is set)
- HDR (PQ or HLG transfer functions)

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
