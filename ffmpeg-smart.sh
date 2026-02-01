#!/bin/bash
if [ -z "$BASH_VERSION" ]; then exec bash "$0" "$@"; fi
set -euo pipefail

LOG_PREFIX="[ffmpeg-smart]"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="841fd67"  # git commit
CACHE_FILE="$SCRIPT_DIR/.capabilities.cache"
PROBE_SAMPLE="$SCRIPT_DIR/probe-sample.mkv"
PROBE_SAMPLE_URL="https://repo.jellyfin.org/archive/jellyfish/media/jellyfish-3-mbps-hd-hevc-10bit.mkv"

# Get hardware fingerprint (GPU vendor:device)
get_hw_fingerprint() {
    local fp=""
    # Linux DRI devices
    for d in /sys/class/drm/card*/device; do
        if [[ -r "$d/vendor" && -r "$d/device" ]]; then
            fp+="$(cat "$d/vendor" 2>/dev/null):$(cat "$d/device" 2>/dev/null);"
        fi
    done
    # NVIDIA
    [[ -e /dev/nvidia0 ]] && fp+="nvidia:$(nvidia-smi --query-gpu=gpu_name --format=csv,noheader 2>/dev/null | head -1 | tr ' ' '_');"
    # macOS
    [[ "$(uname -s)" == "Darwin" ]] && fp+="darwin:$(system_profiler SPDisplaysDataType 2>/dev/null | grep 'Chip' | head -1 | tr ' ' '_');"
    # Fallback
    [[ -z "$fp" ]] && fp="software"
    echo "$fp"
}

# Download probe sample if needed (~4MB jellyfish 10-bit HEVC)
ensure_probe_sample() {
    [[ -f "$PROBE_SAMPLE" ]] && return 0
    echo "$LOG_PREFIX Downloading probe sample (~4MB)..." >&2
    curl -fsSL -o "$PROBE_SAMPLE" "$PROBE_SAMPLE_URL" 2>/dev/null || {
        echo "$LOG_PREFIX WARNING: Failed to download probe sample, using synthetic test" >&2
        return 1
    }
}

# Quick encoder benchmark - returns "speed:lp_speed" (e.g., "4.0:3.5" or "5.2:" if no lp)
# Tests both normal and low_power modes for VAAPI/QSV
bench_encoder() {
    local encoder="$1"
    local pix_fmt="nv12"
    local size="1920x1080"
    local duration="2"  # 2 seconds @ 30fps = 60 frames
    local output speed
    local lp_speed=""

    # Production-like encoder options for realistic benchmarking
    local prod_opts="-b:v 8M -maxrate 10M -bufsize 16M -g 30 -bf 2"
    # Low power mode: no B-frames, no look-ahead (VDEnc requirements)
    local lp_prod_opts="-b:v 8M -maxrate 10M -bufsize 16M -g 30 -bf 0 -look_ahead 0"

    case "$encoder" in
        *_qsv)
            # Test normal mode with production settings
            output=$(timeout 30s ffmpeg -hide_banner -benchmark \
                -init_hw_device qsv=qsv:hw \
                -f lavfi -i "testsrc=size=$size:duration=$duration:rate=30,format=$pix_fmt" \
                -vf "hwupload=extra_hw_frames=16" \
                -c:v "$encoder" -preset faster $prod_opts -f null - 2>&1)
            speed=$(echo "$output" | grep -oP 'speed=\s*\K[0-9.]+(?=x)' | tail -1)
            # Test low power mode (no preset, no B-frames)
            output=$(timeout 30s ffmpeg -hide_banner -benchmark \
                -init_hw_device qsv=qsv:hw \
                -f lavfi -i "testsrc=size=$size:duration=$duration:rate=30,format=$pix_fmt" \
                -vf "hwupload=extra_hw_frames=16" \
                -c:v "$encoder" -low_power true $lp_prod_opts -f null - 2>&1)
            lp_speed=$(echo "$output" | grep -oP 'speed=\s*\K[0-9.]+(?=x)' | tail -1)
            ;;
        *_vaapi)
            # Test normal mode with production settings
            output=$(timeout 30s ffmpeg -hide_banner -benchmark \
                -vaapi_device "${VAAPI_DEVICE:-/dev/dri/renderD128}" \
                -f lavfi -i "testsrc=size=$size:duration=$duration:rate=30,format=$pix_fmt" \
                -vf "hwupload,scale_vaapi=format=$pix_fmt" \
                -c:v "$encoder" -rc_mode VBR $prod_opts -f null - 2>&1)
            speed=$(echo "$output" | grep -oP 'speed=\s*\K[0-9.]+(?=x)' | tail -1)
            # Test low power mode (no B-frames)
            output=$(timeout 30s ffmpeg -hide_banner -benchmark \
                -vaapi_device "${VAAPI_DEVICE:-/dev/dri/renderD128}" \
                -f lavfi -i "testsrc=size=$size:duration=$duration:rate=30,format=$pix_fmt" \
                -vf "hwupload,scale_vaapi=format=$pix_fmt" \
                -c:v "$encoder" -rc_mode VBR -low_power 1 $lp_prod_opts -f null - 2>&1)
            lp_speed=$(echo "$output" | grep -oP 'speed=\s*\K[0-9.]+(?=x)' | tail -1)
            ;;
        *_nvenc)
            output=$(timeout 30s ffmpeg -hide_banner -benchmark \
                -init_hw_device cuda=cuda -filter_hw_device cuda \
                -f lavfi -i "testsrc=size=$size:duration=$duration:rate=30,format=$pix_fmt,hwupload_cuda" \
                -c:v "$encoder" -f null - 2>&1)
            speed=$(echo "$output" | grep -oP 'speed=\s*\K[0-9.]+(?=x)' | tail -1)
            ;;
        *_videotoolbox)
            output=$(timeout 30s ffmpeg -hide_banner -benchmark \
                -f lavfi -i "testsrc=size=$size:duration=$duration:rate=30,format=$pix_fmt" \
                -c:v "$encoder" -f null - 2>&1)
            speed=$(echo "$output" | grep -oP 'speed=\s*\K[0-9.]+(?=x)' | tail -1)
            ;;
        *_v4l2m2m)
            output=$(timeout 30s ffmpeg -hide_banner -benchmark \
                -f lavfi -i "testsrc=size=$size:duration=$duration:rate=30,format=$pix_fmt" \
                -c:v "$encoder" -f null - 2>&1)
            speed=$(echo "$output" | grep -oP 'speed=\s*\K[0-9.]+(?=x)' | tail -1)
            ;;
        *)
            # Software encoders - use faster preset for quick test
            output=$(timeout 30s ffmpeg -hide_banner -benchmark \
                -f lavfi -i "testsrc=size=$size:duration=$duration:rate=30" \
                -c:v "$encoder" -preset ultrafast -f null - 2>&1)
            speed=$(echo "$output" | grep -oP 'speed=\s*\K[0-9.]+(?=x)' | tail -1)
            ;;
    esac

    echo "${speed:-0}:${lp_speed}"
}

# Quick encoder test - returns 0 if works (used for 10-bit capability check)
test_encoder() {
    local encoder="$1"
    local test_10bit="${2:-false}"
    local pix_fmt="nv12"
    [[ "$test_10bit" == "true" ]] && pix_fmt="p010le"
    local size="256x256"

    case "$encoder" in
        *_qsv)
            timeout 10s ffmpeg -hide_banner -v error \
                -init_hw_device qsv=qsv:hw \
                -f lavfi -i "color=black:size=$size:duration=0.1,format=$pix_fmt" \
                -vf "hwupload=extra_hw_frames=16" \
                -c:v "$encoder" -f null - 2>/dev/null
            ;;
        *_vaapi)
            timeout 10s ffmpeg -hide_banner -v error \
                -vaapi_device "${VAAPI_DEVICE:-/dev/dri/renderD128}" \
                -f lavfi -i "color=black:size=$size:duration=0.1,format=$pix_fmt" \
                -vf "hwupload,scale_vaapi=format=$pix_fmt" \
                -c:v "$encoder" -f null - 2>/dev/null
            ;;
        *_nvenc)
            timeout 10s ffmpeg -hide_banner -v error \
                -init_hw_device cuda=cuda -filter_hw_device cuda \
                -f lavfi -i "color=black:size=$size:duration=0.1,format=$pix_fmt,hwupload_cuda" \
                -c:v "$encoder" -f null - 2>/dev/null
            ;;
        *_videotoolbox)
            timeout 10s ffmpeg -hide_banner -v error \
                -f lavfi -i "color=black:size=$size:duration=0.1,format=$pix_fmt" \
                -c:v "$encoder" -f null - 2>/dev/null
            ;;
        *_v4l2m2m)
            timeout 10s ffmpeg -hide_banner -v error \
                -f lavfi -i "color=black:size=$size:duration=0.1,format=$pix_fmt" \
                -c:v "$encoder" -f null - 2>/dev/null
            ;;
        *)
            timeout 10s ffmpeg -hide_banner -v error \
                -f lavfi -i "color=black:size=$size:duration=0.1" \
                -c:v "$encoder" -f null - 2>/dev/null
            ;;
    esac
}

# Test if hwaccel can decode 10-bit HEVC
test_10bit_decode() {
    local accel="$1"
    local hwaccel_args=()

    [[ ! -f "$PROBE_SAMPLE" ]] && return 1

    case "$accel" in
        qsv) hwaccel_args=(-hwaccel qsv -hwaccel_output_format qsv) ;;
        vaapi) hwaccel_args=(-hwaccel vaapi -hwaccel_output_format vaapi -vaapi_device "${VAAPI_DEVICE:-/dev/dri/renderD128}") ;;
        nvenc) hwaccel_args=(-hwaccel cuda -hwaccel_output_format cuda) ;;
        videotoolbox) hwaccel_args=(-hwaccel videotoolbox) ;;
        *) return 1 ;;  # software doesn't need this test
    esac

    timeout 5s ffmpeg -hide_banner -v error \
        "${hwaccel_args[@]}" -t 0.2 -i "$PROBE_SAMPLE" \
        -f null - 2>/dev/null
}

# Probe all encoder capabilities
probe_capabilities() {
    local results=""
    local encoders_list
    encoders_list=$(ffmpeg -hide_banner -encoders 2>/dev/null || true)

    # Try to get real sample for better probe accuracy
    ensure_probe_sample || true

    # Test matrix: accel -> codecs
    local accels_to_test=()
    local can_decode_10bit=""

    # Detect what to test based on hardware
    if [[ "$(uname -s)" == "Darwin" ]]; then
        accels_to_test+=("videotoolbox")
    else
        [[ -e /dev/nvidia0 ]] && accels_to_test+=("nvenc")
        if [[ -e /dev/dri/renderD128 ]]; then
            for v in /sys/class/drm/renderD*/device/vendor; do
                [[ -r "$v" ]] || continue
                case "$(cat "$v" 2>/dev/null)" in
                    0x8086) accels_to_test+=("qsv" "vaapi") ;;
                    0x1002) accels_to_test+=("vaapi") ;;
                esac
                break
            done
        fi
        # V4L2 M2M (ARM: Raspberry Pi, Rockchip, etc.)
        for n in /sys/class/video4linux/video*/name; do
            if [[ -r "$n" ]] && grep -qiE 'm2m|codec' "$n" 2>/dev/null; then
                accels_to_test+=("v4l2m2m")
                break
            fi
        done
    fi
    accels_to_test+=("software")

    local best_accel="software"
    local best_codec="h264"
    local best_speed="0"
    local best_low_power="0"
    local supports_10bit_decode="false"
    local supports_10bit_encode="false"

    for accel in "${accels_to_test[@]}"; do
        # Test 10-bit decode for this accelerator
        if [[ "$accel" != "software" ]] && test_10bit_decode "$accel"; then
            can_decode_10bit+="${accel}=1;"
            supports_10bit_decode="true"
        fi

        for codec in h264 hevc; do
            local encoder
            if [[ "$accel" == "software" ]]; then
                [[ "$codec" == "h264" ]] && encoder="libx264" || encoder="libx265"
            else
                encoder="${codec}_${accel}"
            fi

            # Skip if encoder not compiled in
            grep -qw "$encoder" <<<"$encoders_list" || continue

            local bench_result speed lp_speed best_of_two use_lp
            bench_result=$(bench_encoder "$encoder")
            speed="${bench_result%%:*}"
            lp_speed="${bench_result##*:}"

            if [[ -n "$speed" && "$speed" != "0" ]]; then
                # Store normal mode result
                results+="${encoder}=${speed}x;"

                # Store low power result if tested
                if [[ -n "$lp_speed" && "$lp_speed" != "0" ]]; then
                    results+="${encoder}(lp)=${lp_speed}x;"
                fi

                # Determine which mode is faster for this encoder
                if [[ -n "$lp_speed" ]] && awk "BEGIN {exit !($lp_speed > $speed)}"; then
                    best_of_two="$lp_speed"
                    use_lp="1"
                else
                    best_of_two="$speed"
                    use_lp="0"
                fi

                # Compare to overall best (use awk for float comparison)
                if awk "BEGIN {exit !($best_of_two > $best_speed)}"; then
                    best_speed="$best_of_two"
                    best_accel="$accel"
                    best_codec="$codec"
                    best_low_power="$use_lp"
                fi

                # Test 10-bit encode for HEVC (skip QSV - known broken)
                if [[ "$codec" == "hevc" && "$accel" != "software" && "$accel" != "qsv" ]]; then
                    if test_encoder "$encoder" "true"; then
                        results+="${encoder}_10bit=1;"
                        supports_10bit_encode="true"
                    fi
                fi
            else
                results+="${encoder}=0;"
            fi
        done
    done

    echo "BEST_ACCEL='$best_accel'"
    echo "BEST_CODEC='$best_codec'"
    echo "BEST_LOW_POWER='$best_low_power'"
    echo "SUPPORTS_10BIT_DECODE='$supports_10bit_decode'"
    echo "SUPPORTS_10BIT_ENCODE='$supports_10bit_encode'"
    echo "DECODE_10BIT='$can_decode_10bit'"
    echo "ENCODERS='$results'"
}

# Load cached capabilities (returns 1 if cache invalid)
load_cache() {
    [[ -f "$CACHE_FILE" ]] || return 1

    # Source first to get variables
    source "$CACHE_FILE" || return 1

    # Check fingerprint matches
    local current_fp
    current_fp=$(get_hw_fingerprint)
    [[ "$HW_FINGERPRINT" == "$current_fp" ]] || return 1

    return 0
}

# Save capabilities to cache
save_cache() {
    {
        echo "# ffmpeg-smart capability cache"
        echo "# Generated: $(date -Iseconds)"
        echo "HW_FINGERPRINT='$(get_hw_fingerprint)'"
        probe_capabilities
    } > "$CACHE_FILE"
    source "$CACHE_FILE"
}

# Parse args
AGENT=""
URL=""
VCODEC_OUT=""  # empty = use cached best
ALLOW_10BIT="" # empty = use cached value
ALLOW_HDR=""   # empty = use cached value
RECACHE=false

# Placeholder - will be set from cache or detect_accel fallback
ACCEL="__auto__"

# Fallback accel detection (only used if cache fails)
detect_accel() {
    # macOS - VideoToolbox
    if [[ "$(uname -s)" == "Darwin" ]]; then
        echo "videotoolbox"; return
    fi
    # NVIDIA
    if [[ -e /dev/nvidia0 ]]; then
        echo "nvenc"; return
    fi
    # Check DRI vendor for Intel/AMD
    local vendor
    for v in /sys/class/drm/renderD*/device/vendor; do
        [[ -r "$v" ]] || continue
        vendor=$(cat "$v" 2>/dev/null)
        case "$vendor" in
            0x8086) echo "vaapi"; return ;; # Intel
            0x1002) echo "vaapi"; return ;; # AMD
        esac
    done
    # V4L2 M2M (ARM: Raspberry Pi, Rockchip, etc.)
    for n in /sys/class/video4linux/video*/name; do
        [[ -r "$n" ]] && grep -qiE 'm2m|codec' "$n" && echo "v4l2m2m" && return
    done
    # Fallback to vaapi if DRI exists, else software
    if [[ -e /dev/dri/renderD128 ]]; then
        echo "vaapi"
    else
        echo "software"
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -user_agent) AGENT="$2"; shift 2 ;;
        -i) URL="$2"; shift 2 ;;
        -accel) ACCEL="$2"; shift 2 ;;
        -vc) VCODEC_OUT="$2"; shift 2 ;;
        -10bit) ALLOW_10BIT=true; shift ;;
        -hdr) ALLOW_HDR=true; shift ;;
        --recache) RECACHE=true; shift ;;
        *) shift ;;
    esac
done

# Initialize capabilities from cache (or probe if needed)
if [[ "$RECACHE" == "true" ]] || ! load_cache 2>/dev/null; then
    save_cache
    echo "$LOG_PREFIX v$VERSION | Probed: accel=$BEST_ACCEL codec=$BEST_CODEC 10bit=$SUPPORTS_10BIT_ENCODE hdr=$SUPPORTS_10BIT_ENCODE" >&2
else
    echo "$LOG_PREFIX v$VERSION | Cached: accel=$BEST_ACCEL codec=$BEST_CODEC 10bit=$SUPPORTS_10BIT_ENCODE hdr=$SUPPORTS_10BIT_ENCODE" >&2
fi

# Apply cached defaults if not overridden by args
[[ -z "$VCODEC_OUT" ]] && VCODEC_OUT="${BEST_CODEC:-h264}"
[[ -z "$ALLOW_10BIT" || "$ALLOW_10BIT" == "" ]] && ALLOW_10BIT="${SUPPORTS_10BIT_ENCODE:-false}"
[[ -z "$ALLOW_HDR" || "$ALLOW_HDR" == "" ]] && ALLOW_HDR="${SUPPORTS_10BIT_ENCODE:-false}"  # HDR requires 10-bit encode
if [[ "$ACCEL" == "__auto__" ]]; then
    ACCEL="${BEST_ACCEL:-}"
    [[ -z "$ACCEL" ]] && ACCEL=$(detect_accel)
fi

# Validate
if [[ -z "$URL" ]]; then
    echo "$LOG_PREFIX ERROR: No stream URL provided" >&2
    exit 1
fi

# Cache encoder list for codec selection
ENCODERS="$(ffmpeg -hide_banner -encoders 2>/dev/null || true)"

# Validate accel type
case "$ACCEL" in
    qsv|vaapi|nvenc|v4l2m2m|videotoolbox|software) ;;
    *)
        echo "$LOG_PREFIX ERROR: Unknown accel type: $ACCEL (use: qsv, vaapi, nvenc, v4l2m2m, videotoolbox, software)" >&2
        exit 1
        ;;
esac

case "$VCODEC_OUT" in
    h264|hevc) ;;
    *)
        echo "$LOG_PREFIX ERROR: Unknown video codec: $VCODEC_OUT (use: h264, hevc)" >&2
        exit 1
        ;;
esac

# Set hwaccel args (called early for decoding)
set_hwaccel_args() {
    case "$ACCEL" in
        qsv)
            HWACCEL_ARGS=( -hwaccel qsv -hwaccel_output_format qsv )
            ;;
        vaapi)
            HWACCEL_ARGS=( -hwaccel vaapi -hwaccel_output_format vaapi -vaapi_device "${VAAPI_DEVICE:-/dev/dri/renderD128}" )
            ;;
        nvenc)
            HWACCEL_ARGS=( -hwaccel cuda -hwaccel_output_format cuda )
            ;;
        videotoolbox)
            HWACCEL_ARGS=( -hwaccel videotoolbox )
            ;;
        *)
            HWACCEL_ARGS=()
            ;;
    esac
}

# Set encoder-specific options (called after encoder selection)
set_encoder_opts() {
    # Default: enable B-frames for better compression
    BF_ARGS="-bf 2"

    case "$ACCEL" in
        qsv)
            if [[ "${BEST_LOW_POWER:-0}" == "1" ]]; then
                # Low power (VDEnc): no preset, no B-frames, no look-ahead
                ACCEL_OPTS="-low_power true -look_ahead 0"
                BF_ARGS="-bf 0"
            else
                ACCEL_OPTS="-preset faster"
            fi
            ;;
        vaapi)
            ACCEL_OPTS="-rc_mode VBR"
            if [[ "${BEST_LOW_POWER:-0}" == "1" ]]; then
                ACCEL_OPTS+=" -low_power 1"
                BF_ARGS="-bf 0"  # Low power mode doesn't support B-frames
            fi
            ;;
        nvenc)
            ACCEL_OPTS="-preset p4 -rc vbr"
            ;;
        videotoolbox)
            ACCEL_OPTS="-realtime false"
            ;;
        software)
            ACCEL_OPTS="-preset faster"
            ;;
        *)
            ACCEL_OPTS=""
            ;;
    esac
}

# Build network-specific args (only for HTTP/HTTPS)
if [[ "$URL" =~ ^https?:// ]]; then
    [[ -n "$AGENT" ]] && UA_ARGS=(-user_agent "$AGENT") || UA_ARGS=()
    NET_ARGS=(-reconnect 1 -reconnect_at_eof 1 -reconnect_streamed 1 -reconnect_delay_max 30 -rw_timeout 15000000)
else
    UA_ARGS=()
    NET_ARGS=()
fi

# Probe stream
PROBE=$(ffprobe "${UA_ARGS[@]}" -v quiet -print_format json -show_streams "$URL" 2>&1) || {
    echo "$LOG_PREFIX ERROR: ffprobe failed - cannot access stream" >&2
    exit 1
}

# Parse streams by codec_type
VCODEC=$(echo "$PROBE" | jq -r '.streams[] | select(.codec_type=="video") | .codec_name' | head -n1)
FPS_FRAC=$(echo "$PROBE" | jq -r '.streams[] | select(.codec_type=="video") | .r_frame_rate' | head -n1)
PIX_FMT=$(echo "$PROBE" | jq -r '.streams[] | select(.codec_type=="video") | .pix_fmt // empty' | head -n1)
COLOR_TRANSFER=$(echo "$PROBE" | jq -r '.streams[] | select(.codec_type=="video") | .color_transfer // empty' | head -n1)
WIDTH=$(echo "$PROBE" | jq -r '.streams[] | select(.codec_type=="video") | .width // 0' | head -n1)
HEIGHT=$(echo "$PROBE" | jq -r '.streams[] | select(.codec_type=="video") | .height // 0' | head -n1)
ABITRATE_RAW=$(echo "$PROBE" | jq -r '.streams[] | select(.codec_type=="audio") | .bit_rate // empty' | head -n1)
ACHANNELS=$(echo "$PROBE" | jq -r '.streams[] | select(.codec_type=="audio") | .channels // empty' | head -n1)

# Passthrough conditions:
# - 4K+ resolution (no point re-encoding)
# - 10-bit content when can't encode 10-bit
# - HDR content when can't encode HDR (requires 10-bit HEVC)
PASSTHROUGH=""
IS_HDR=false
[[ "$COLOR_TRANSFER" == "smpte2084" || "$COLOR_TRANSFER" == "arib-std-b67" ]] && IS_HDR=true

if [[ "$WIDTH" -ge 3840 || "$HEIGHT" -ge 2160 ]]; then
    PASSTHROUGH="4K+"
elif [[ "$PIX_FMT" == *"10"* && "$ALLOW_10BIT" == "false" ]]; then
    PASSTHROUGH="10-bit"
elif [[ "$IS_HDR" == "true" && "$ALLOW_HDR" == "false" ]]; then
    PASSTHROUGH="HDR"
fi

# Validate video stream
if [[ -z "$VCODEC" || "$VCODEC" == "null" ]]; then
    echo "$LOG_PREFIX ERROR: No video stream found" >&2
    exit 1
fi

# Select encoder based on VCODEC_OUT family and acceleration
if [[ "$ACCEL" == "software" ]]; then
    if [[ "$VCODEC_OUT" == "hevc" ]]; then
        ENCODER="libx265"
        TAG_ARGS="-tag:v hvc1"
    else
        ENCODER="libx264"
        TAG_ARGS=""
    fi
else
    ENCODER="${VCODEC_OUT}_${ACCEL}"
    if ! grep -qw "$ENCODER" <<<"$ENCODERS"; then
        echo "$LOG_PREFIX ERROR: Encoder $ENCODER not available" >&2
        exit 1
    fi
    if [[ "$VCODEC_OUT" == "hevc" ]]; then
        TAG_ARGS="-tag:v hvc1"
    else
        TAG_ARGS=""
    fi
fi

# Set hwaccel args and encoder-specific options
set_hwaccel_args
set_encoder_opts

# Handle video filter requirements:
# 1. 10-bit input for H264 output needs conversion to 8-bit
# 2. Cross-codec transcode with VAAPI needs scale_vaapi for frame format compatibility
VF_ARGS=""
if [[ "$PIX_FMT" == *"10"* && "$VCODEC_OUT" == "h264" ]]; then
    # H264 can't encode 10-bit, must convert to 8-bit
    case "$ACCEL" in
        nvenc) VF_ARGS="-vf scale_cuda=format=nv12" ;;
        vaapi) VF_ARGS="-vf scale_vaapi=format=nv12" ;;
        qsv) VF_ARGS="-vf scale_qsv=format=nv12" ;;
        *) VF_ARGS="-pix_fmt yuv420p" ;;
    esac
elif [[ "$ACCEL" == "vaapi" || "$ACCEL" == "qsv" ]]; then
    # VAAPI/QSV encode needs format conversion filter
    # hwupload passthrough handles both hw decode (pass through) and sw decode fallback (upload)
    case "$ACCEL" in
        vaapi) VF_ARGS="-vf format=nv12|vaapi,hwupload,scale_vaapi=format=nv12" ;;
        qsv) VF_ARGS="-vf scale_qsv=format=nv12" ;;
    esac
fi

# HDR metadata passthrough (only for HEVC, H264 doesn't support HDR)
HDR_ARGS=""
if [[ "$IS_HDR" == "true" && "$VCODEC_OUT" == "hevc" && "$ALLOW_HDR" == "true" ]]; then
    # Preserve HDR color metadata
    HDR_ARGS="-color_primaries bt2020 -color_trc $COLOR_TRANSFER -colorspace bt2020nc"
fi

# Validate audio bitrate (reject sample rates like 44100/48000)
# Audio bitrate: use source if valid, else 64kbps per channel
if [[ -n "$ABITRATE_RAW" ]] && [[ "$ABITRATE_RAW" =~ ^[0-9]+$ ]] && [[ "$ABITRATE_RAW" -ge 60000 ]] && [[ "$ABITRATE_RAW" -le 500000 ]]; then
    ABITRATE="$ABITRATE_RAW"
else
    ACHANNELS_NUM=${ACHANNELS:-2}
    [[ "$ACHANNELS_NUM" =~ ^[0-9]+$ ]] || ACHANNELS_NUM=2
    ABITRATE=$((64000 * ACHANNELS_NUM))
fi

# Set channel layout based on channel count
case "$ACHANNELS" in
    1) CHANNEL_LAYOUT="-ch_layout mono" ;;
    2) CHANNEL_LAYOUT="-ch_layout stereo" ;;
    6) CHANNEL_LAYOUT="-ch_layout 5.1" ;;
    8) CHANNEL_LAYOUT="-ch_layout 7.1" ;;
    *)
        CHANNEL_LAYOUT="-ac 2 -ch_layout stereo"
        ACHANNELS="${ACHANNELS:-0} -> 2 (forced)"
        ;;
esac

# Video bitrate scaled quadratically by pixels (8Mbps base at 1080p, 2Mbps floor)
BASE_VBITRATE=8000000
VBITRATE=$((BASE_VBITRATE * WIDTH * HEIGHT / 1920 / 1080))
[[ $VBITRATE -lt 2000000 ]] && VBITRATE=2000000
MAXRATE=$((VBITRATE * 125 / 100))  # 1.25x
BUFSIZE=$((VBITRATE * 2))

# Calculate GOP with rounding
if [[ "$FPS_FRAC" =~ ^([0-9]+)/([0-9]+)$ ]]; then
    NUM=${BASH_REMATCH[1]}
    DEN=${BASH_REMATCH[2]}
    if [[ $DEN -gt 0 ]]; then
        GOP=$(( (NUM + DEN/2) / DEN ))
        FPS_OUT="$FPS_FRAC"
        GOP_WARN=""
    else
        GOP=50
        FPS_OUT="25/1"
        GOP_WARN=" (invalid fps denominator)"
    fi
else
    GOP=50
    FPS_OUT="25/1"
    GOP_WARN=" (fps parse failed)"
fi

if [[ -n "$PASSTHROUGH" ]]; then
    echo "$LOG_PREFIX Detected ${WIDTH}x${HEIGHT} $VCODEC/$PIX_FMT @ $FPS_FRAC -> passthrough (${PASSTHROUGH}) audio=${ABITRATE}bps ${ACHANNELS}ch" >&2
    exec ffmpeg \
        "${UA_ARGS[@]}" \
        "${NET_ARGS[@]}" \
        -fflags +genpts+igndts+discardcorrupt \
        -err_detect ignore_err \
        -i "$URL" \
        -map 0:v:0 \
        -map 0:a:0? \
        -c:v copy \
        -c:a aac \
        -b:a "$ABITRATE" \
        $CHANNEL_LAYOUT \
        -af "aresample=async=1" \
        -avoid_negative_ts make_zero \
        -start_at_zero \
        -mpegts_copyts 0 \
        -mpegts_flags +pat_pmt_at_frames+resend_headers \
        -flush_packets 1 \
        -max_muxing_queue_size 4096 \
        -f mpegts \
        pipe:1
fi

echo "$LOG_PREFIX Detected ${WIDTH}x${HEIGHT} $VCODEC/$PIX_FMT @ $FPS_FRAC -> $ENCODER GOP=$GOP${GOP_WARN} audio=${ABITRATE}bps ${ACHANNELS}ch accel=${ACCEL}" >&2

exec ffmpeg \
    "${UA_ARGS[@]}" \
    "${NET_ARGS[@]}" \
    "${HWACCEL_ARGS[@]}" \
    -reinit_filter 0 \
    -fflags +genpts+igndts+discardcorrupt \
    -err_detect ignore_err \
    -i "$URL" \
    -map 0:v:0 \
    -map 0:a:0? \
    -c:v "$ENCODER" \
    $VF_ARGS \
    $HDR_ARGS \
    -b:v "$VBITRATE" \
    -maxrate "$MAXRATE" \
    -bufsize "$BUFSIZE" \
    -g "$GOP" \
    $BF_ARGS \
    ${ACCEL_OPTS} \
    -fps_mode cfr \
    -r "$FPS_OUT" \
    $TAG_ARGS \
    -c:a aac \
    -b:a "$ABITRATE" \
    $CHANNEL_LAYOUT \
    -af "aresample=async=1" \
    -avoid_negative_ts make_zero \
    -start_at_zero \
    -mpegts_copyts 0 \
    -mpegts_flags +pat_pmt_at_frames+resend_headers \
    -flush_packets 1 \
    -max_muxing_queue_size 4096 \
    -f mpegts \
    pipe:1
