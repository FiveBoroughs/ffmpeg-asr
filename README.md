# ffmpeg-asr

Adaptive stream re-encoder with automatic hardware acceleration detection.

## What it does

Wraps ffmpeg to transcode streams with hardware acceleration when available. Auto-detects your GPU and picks the right encoder. Passes through content that shouldn't be re-encoded (4K, HDR, 10-bit on most hardware).

## Usage

```bash
./ffmpeg-smart.sh -i "stream_url" -user_agent "User-Agent"
```

Outputs MPEG-TS to stdout.

Override auto-detected acceleration:
```bash
./ffmpeg-smart.sh -i "stream_url" -user_agent "UA" -accel nvenc
```

Supported: `qsv`, `vaapi`, `nvenc`, `videotoolbox`, `v4l2m2m`, `software`

## Passthrough

Video is passed through (not re-encoded) when:
- Resolution is 4K or higher
- 10-bit content (except on NVENC which handles it fine)
- HDR (PQ or HLG transfer functions)

## Hardware detection order

1. macOS → VideoToolbox
2. `/dev/nvidia0` exists → NVENC
3. Intel GPU → VAAPI
4. AMD GPU → VAAPI
5. V4L2 M2M device (ARM boards) → V4L2M2M
6. DRI device exists → VAAPI
7. Nothing found → software
