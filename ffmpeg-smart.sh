#!/bin/bash
if [ -z "$BASH_VERSION" ]; then exec bash "$0" "$@"; fi
set -euo pipefail

LOG_PREFIX="[ffmpeg-smart]"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="09adc9b"  # git commit
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

# Quick encoder test (few frames) - returns 0 if works
test_encoder() {
    local encoder="$1"
    local test_10bit="${2:-false}"
    local hwaccel_args=()
    local input_args=()
    local filter_args=()

    # Use real sample if available, otherwise synthetic
    if [[ -f "$PROBE_SAMPLE" ]]; then
        input_args=(-t 0.5 -i "$PROBE_SAMPLE")
    else
        input_args=(-f lavfi -i "testsrc=duration=0.5:size=320x240")
    fi

    # Set up hwaccel decode + encode pipeline
    # Note: probe sample is 10-bit HEVC, so h264 encoders need format conversion to 8-bit
    case "$encoder" in
        h264_qsv)
            hwaccel_args=(-hwaccel qsv -hwaccel_output_format qsv)
            filter_args=(-vf "scale_qsv=format=nv12")
            ;;
        hevc_qsv)
            hwaccel_args=(-hwaccel qsv -hwaccel_output_format qsv)
            [[ "$test_10bit" == "true" ]] && filter_args=(-vf "scale_qsv=format=p010le")
            ;;
        h264_vaapi)
            hwaccel_args=(-hwaccel vaapi -hwaccel_output_format vaapi -vaapi_device "${VAAPI_DEVICE:-/dev/dri/renderD128}")
            filter_args=(-vf "scale_vaapi=format=nv12")
            ;;
        hevc_vaapi)
            hwaccel_args=(-hwaccel vaapi -hwaccel_output_format vaapi -vaapi_device "${VAAPI_DEVICE:-/dev/dri/renderD128}")
            [[ "$test_10bit" == "true" ]] && filter_args=(-vf "scale_vaapi=format=p010")
            ;;
        h264_nvenc)
            hwaccel_args=(-hwaccel cuda -hwaccel_output_format cuda)
            filter_args=(-vf "scale_cuda=format=nv12")
            ;;
        hevc_nvenc)
            hwaccel_args=(-hwaccel cuda -hwaccel_output_format cuda)
            [[ "$test_10bit" == "true" ]] && filter_args=(-vf "scale_cuda=format=p010le")
            ;;
        *_v4l2m2m)
            hwaccel_args=()
            filter_args=(-pix_fmt nv12)
            ;;
        *_videotoolbox)
            hwaccel_args=(-hwaccel videotoolbox)
            ;;
        *)
            hwaccel_args=()
            ;;
    esac

    timeout 10s ffmpeg -hide_banner -v error \
        "${hwaccel_args[@]}" "${input_args[@]}" \
        "${filter_args[@]}" -c:v "$encoder" -f null - 2>/dev/null
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

            echo "$LOG_PREFIX Probing $encoder..." >&2
            if test_encoder "$encoder"; then
                results+="${encoder}=1;"
                # First working HW encoder wins as best
                if [[ "$accel" != "software" && "$best_accel" == "software" ]]; then
                    best_accel="$accel"
                    best_codec="$codec"
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
    echo "$LOG_PREFIX v$VERSION | Probing encoder capabilities..." >&2
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
    case "$ACCEL" in
        qsv)
            ACCEL_OPTS="-preset faster"
            ;;
        vaapi)
            ACCEL_OPTS="-rc_mode VBR"
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

# Handle 10-bit input: H264 needs conversion to 8-bit, HEVC can keep 10-bit if supported
VF_ARGS=""
if [[ "$PIX_FMT" == *"10"* && "$VCODEC_OUT" == "h264" ]]; then
    # H264 can't encode 10-bit, must convert to 8-bit
    case "$ACCEL" in
        nvenc) VF_ARGS="-vf scale_cuda=format=nv12" ;;
        vaapi) VF_ARGS="-vf scale_vaapi=format=nv12" ;;
        qsv) VF_ARGS="-vf scale_qsv=format=nv12" ;;
        *) VF_ARGS="-pix_fmt yuv420p" ;;
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
    -bf 2 \
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
