#!/bin/bash
if [ -z "$BASH_VERSION" ]; then exec bash "$0" "$@"; fi
set -euo pipefail

LOG_PREFIX="[ffmpeg-smart]"

# Parse args
AGENT=""
URL=""
VCODEC_OUT="h264"  # h264 (faster) or hevc (smaller)
ALLOW_10BIT=false  # set true if hardware supports 10-bit encoding

# Auto-detect default accel based on available hardware
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
ACCEL=$(detect_accel)

while [[ $# -gt 0 ]]; do
    case "$1" in
        -user_agent) AGENT="$2"; shift 2 ;;
        -i) URL="$2"; shift 2 ;;
        -accel) ACCEL="$2"; shift 2 ;;
        -vc) VCODEC_OUT="$2"; shift 2 ;;
        -10bit) ALLOW_10BIT=true; shift ;;
        *) shift ;;
    esac
done

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
# - 10-bit content on QSV (can't encode properly)
# - HDR content (preserve HDR, don't tone map)
PASSTHROUGH=""
if [[ "$WIDTH" -ge 3840 || "$HEIGHT" -ge 2160 ]]; then
    PASSTHROUGH="4K+"
elif [[ "$PIX_FMT" == *"10"* && "$ALLOW_10BIT" == "false" ]]; then
    PASSTHROUGH="10-bit"
elif [[ "$COLOR_TRANSFER" == "smpte2084" || "$COLOR_TRANSFER" == "arib-std-b67" ]]; then
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
