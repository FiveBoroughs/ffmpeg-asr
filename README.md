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

## Benchmarking

The auto-detected encoder isn't always the fastest for your setup. Intel QSV is often cited as faster than VAAPI, but in practice this varies - on some systems (particularly in containers), VAAPI outperforms QSV by 25-30%.

Run the benchmark to find what works best on your hardware:

```bash
./benchmark-accel.sh [duration] [runs]
./benchmark-accel.sh 10 3  # 10 seconds per test, 3 runs each
```

This downloads Jellyfin's demo video files (H.264, HEVC, HEVC 10-bit) and benchmarks all available encoders. Results are saved to `benchmark-results/`. Use the fastest encoder with `-accel`:

```bash
./ffmpeg-smart.sh -i "stream_url" -user_agent "UA" -accel vaapi
```
