#!/bin/bash
set -euo pipefail

# Benchmark ffmpeg-smart.sh against live streams and sample files
# Tests the actual production script with various encoder/codec combinations

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SAMPLES_DIR="$SCRIPT_DIR/benchmark-samples"
RESULTS_DIR="$SCRIPT_DIR/benchmark-results"
DURATION="${1:-15}"
MODE="${2:-all}"  # all, live, local

mkdir -p "$RESULTS_DIR"

# Public test streams (may change or go offline)
declare -A LIVE_STREAMS=(
    ["cnn_720p_h264"]="https://turnerlive.warnermediacdn.com/hls/live/586495/cnngo/cnn_slate/VIDEO_0_3564000.m3u8"
)

# Check dependencies
check_deps() {
    local missing=()
    command -v ffmpeg >/dev/null || missing+=("ffmpeg")
    command -v jq >/dev/null || missing+=("jq")

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "ERROR: Missing dependencies: ${missing[*]}" >&2
        exit 1
    fi
}

# Run single benchmark
run_benchmark() {
    local sample="$1"
    local accel="$2"
    local codec="$3"
    local extra_args="${4:-}"
    local is_live="${5:-false}"

    local stats_file="/tmp/bench_stats_$$.log"
    local smart_log="/tmp/bench_smart_$$.log"

    # Build command based on source type
    if [[ "$is_live" == "true" ]]; then
        "$SCRIPT_DIR/ffmpeg-smart.sh" \
            -i "$sample" \
            -user_agent "Mozilla/5.0" \
            -accel "$accel" \
            -vc "$codec" \
            $extra_args \
            2>"$smart_log" | \
            timeout $((DURATION + 10))s ffmpeg -hide_banner -f mpegts -i pipe:0 -t "$DURATION" -f null - 2>&1 | \
            tee "$stats_file" >/dev/null || true
    else
        "$SCRIPT_DIR/ffmpeg-smart.sh" \
            -i "$sample" \
            -accel "$accel" \
            -vc "$codec" \
            $extra_args \
            2>"$smart_log" | \
            timeout $((DURATION + 5))s ffmpeg -hide_banner -f mpegts -i pipe:0 -t "$DURATION" -f null - 2>&1 | \
            tee "$stats_file" >/dev/null || true
    fi

    # Parse results
    local last_stats frames fps speed
    last_stats=$(tr '\r' '\n' < "$stats_file" | grep "^frame=" | tail -1 || echo "")

    if [[ -n "$last_stats" ]]; then
        frames=$(echo "$last_stats" | sed -n 's/.*frame= *\([0-9]*\).*/\1/p')
        fps=$(echo "$last_stats" | sed -n 's/.*fps= *\([0-9.]*\).*/\1/p')
        speed=$(echo "$last_stats" | sed -n 's/.*speed= *\([0-9.]*\)x.*/\1/p')
    else
        frames=0
        fps=0
        speed=0
    fi

    rm -f "$stats_file" "$smart_log"

    echo "$frames,$fps,$speed"
}

# Main benchmark loop
run_all_benchmarks() {
    local results_csv="$RESULTS_DIR/smart_results_$(date +%Y%m%d_%H%M%S).csv"

    echo "source,accel,codec,extra,frames,fps,speed" > "$results_csv"

    echo "=============================================="
    echo "ffmpeg-smart.sh Benchmark"
    echo "Duration: ${DURATION}s per test"
    echo "=============================================="
    echo ""

    # Test samples
    local samples=()
    [[ -f "$SAMPLES_DIR/hevc_1080p.mkv" ]] && samples+=("hevc_1080p:$SAMPLES_DIR/hevc_1080p.mkv")
    [[ -f "$SAMPLES_DIR/h264_1080p.mkv" ]] && samples+=("h264_1080p:$SAMPLES_DIR/h264_1080p.mkv")
    [[ -f "$SAMPLES_DIR/hevc_10bit_1080p.mkv" ]] && samples+=("hevc_10bit:$SAMPLES_DIR/hevc_10bit_1080p.mkv")

    # Detect available accelerators
    local accels=()
    if [[ -e /dev/dri/renderD128 ]]; then
        for v in /sys/class/drm/renderD*/device/vendor; do
            [[ -r "$v" ]] || continue
            local vendor
            vendor=$(cat "$v" 2>/dev/null)
            case "$vendor" in
                0x8086) accels+=("qsv" "vaapi") ;;
                0x1002) accels+=("vaapi") ;;
            esac
            break
        done
    fi
    [[ -e /dev/nvidia0 ]] && accels+=("nvenc")
    accels+=("software")

    # Remove duplicates
    local unique_accels=()
    for a in "${accels[@]}"; do
        local found=0
        for u in "${unique_accels[@]:-}"; do
            [[ "$a" == "$u" ]] && found=1 && break
        done
        [[ $found -eq 0 ]] && unique_accels+=("$a")
    done
    accels=("${unique_accels[@]}")

    echo "Detected accelerators: ${accels[*]}"
    echo ""

    # Test live streams first
    if [[ "$MODE" == "all" || "$MODE" == "live" ]]; then
        echo "=== LIVE STREAMS ==="
        echo ""
        for stream_name in "${!LIVE_STREAMS[@]}"; do
            local stream_url="${LIVE_STREAMS[$stream_name]}"
            echo "=== Source: $stream_name (LIVE) ==="

            for accel in "${accels[@]}"; do
                for codec in h264 hevc; do
                    local extra=""
                    [[ "$codec" == "hevc" && "$accel" != "qsv" ]] && extra="-10bit"

                    printf "  %-10s %-5s " "$accel" "$codec"

                    result=$(run_benchmark "$stream_url" "$accel" "$codec" "$extra" "true" 2>/dev/null || echo "0,0,0")

                    IFS=',' read -r frames fps speed <<< "$result"

                    if [[ -n "$frames" && "$frames" -gt 0 ]]; then
                        printf "%5s frames, %6s fps, %5sx realtime\n" "$frames" "$fps" "$speed"
                        echo "$stream_name,$accel,$codec,$extra,$frames,$fps,$speed" >> "$results_csv"
                    else
                        echo "FAILED"
                    fi
                done
            done
            echo ""
        done
    fi

    # Test local samples
    if [[ "$MODE" == "all" || "$MODE" == "local" ]]; then
        echo "=== LOCAL SAMPLES ==="
        echo ""
    fi

    for sample_entry in "${samples[@]}"; do
        [[ "$MODE" == "live" ]] && continue
        local source_name="${sample_entry%%:*}"
        local sample="${sample_entry#*:}"

        echo "=== Source: $source_name ==="

        for accel in "${accels[@]}"; do
            for codec in h264 hevc; do
                local extra=""
                # Enable 10-bit for hevc on capable hardware
                [[ "$codec" == "hevc" && "$accel" != "qsv" ]] && extra="-10bit"

                printf "  %-10s %-5s " "$accel" "$codec"

                result=$(run_benchmark "$sample" "$accel" "$codec" "$extra" 2>/dev/null || echo "0,0,0")

                IFS=',' read -r frames fps speed <<< "$result"

                if [[ -n "$frames" && "$frames" -gt 0 ]]; then
                    printf "%5s frames, %6s fps, %5sx realtime\n" "$frames" "$fps" "$speed"
                    echo "$source_name,$accel,$codec,$extra,$frames,$fps,$speed" >> "$results_csv"
                else
                    echo "FAILED"
                fi
            done
        done
        echo ""
    done

    echo "=============================================="
    echo "Results saved to: $results_csv"
    echo "=============================================="
}

# Download samples if needed
check_samples() {
    if [[ ! -d "$SAMPLES_DIR" ]] || [[ -z "$(ls -A "$SAMPLES_DIR" 2>/dev/null)" ]]; then
        echo "Sample files not found. Run benchmark-accel.sh first to download them."
        exit 1
    fi

    echo "Using samples from: $SAMPLES_DIR"
    ls -1 "$SAMPLES_DIR"/*.mkv 2>/dev/null | head -5
    echo ""
}

# Main
echo "=============================================="
echo "FFmpeg Smart Script Benchmark"
echo "=============================================="
echo "Usage: $0 [duration] [mode]"
echo "  duration: seconds per test (default: 15)"
echo "  mode: all, live, local (default: all)"
echo ""

check_deps
[[ "$MODE" != "live" ]] && check_samples
run_all_benchmarks
