#!/bin/bash
set -euo pipefail

LOG_PREFIX="[ffmpeg-smart]"

# Parse args
AGENT=""
URL=""

while [[ $# -gt 0 ]]; do
    if [[ "$1" == "-user_agent" ]]; then
        AGENT="$2"
        shift 2
    elif [[ "$1" == "-i" ]]; then
        URL="$2"
        shift 2
    else
        shift
    fi
done

# Validate URL
if [[ -z "$URL" ]]; then
    echo "$LOG_PREFIX ERROR: No stream URL provided" >&2
    exit 1
fi

# Probe stream (silent)
PROBE=$(ffprobe -v quiet -print_format json -show_streams "$URL" 2>&1) || {
    echo "$LOG_PREFIX ERROR: ffprobe failed - cannot access stream" >&2
    exit 1
}

# Parse streams
VCODEC=$(echo "$PROBE" | jq -r '.streams[] | select(.codec_type=="video") | .codec_name' | head -n1)
FPS_FRAC=$(echo "$PROBE" | jq -r '.streams[] | select(.codec_type=="video") | .r_frame_rate' | head -n1)
ABITRATE=$(echo "$PROBE" | jq -r '.streams[] | select(.codec_type=="audio") | .bit_rate // "128000"' | head -n1)

# Validate video stream
if [[ -z "$VCODEC" || "$VCODEC" == "null" ]]; then
    echo "$LOG_PREFIX ERROR: No video stream found" >&2
    exit 1
fi

# Set video codec
if [[ "$VCODEC" == "hevc" ]]; then
    VCODEC_OUT="hevc_qsv"
elif [[ "$VCODEC" == "h264" ]]; then
    VCODEC_OUT="h264_qsv"
elif [[ "$VCODEC" == "mpeg2video" ]]; then
    VCODEC_OUT="mpeg2_qsv"
else
    # Fallback: transcode unknown codecs to H.264
    VCODEC_OUT="h264_qsv"
fi

# Bitrates
VBITRATE="8000000"
MAXRATE="10000000"
BUFSIZE="20000000"

# Calculate GOP with rounding
if [[ "$FPS_FRAC" =~ ^([0-9]+)/([0-9]+)$ ]]; then
    NUM=${BASH_REMATCH[1]}
    DEN=${BASH_REMATCH[2]}
    GOP=$(( (NUM + DEN/2) / DEN ))
    GOP_WARN=""
else
    GOP=50
    GOP_WARN=" (fps parse failed)"
fi

# Single combined log line with all info
echo "$LOG_PREFIX Detected $VCODEC @ $FPS_FRAC -> $VCODEC_OUT GOP=$GOP${GOP_WARN} audio=${ABITRATE}bps" >&2

# Execute ffmpeg
exec ffmpeg -user_agent "$AGENT" -hwaccel qsv -hwaccel_output_format qsv -reconnect 1 -reconnect_at_eof 1 -reconnect_streamed 1 -reconnect_delay_max 30 -rw_timeout 15000000 -fflags +genpts+discardcorrupt -err_detect ignore_err -i "$URL" -map 0:v:0 -map 0:a:0 -c:v "$VCODEC_OUT" -preset fast -b:v "$VBITRATE" -maxrate "$MAXRATE" -bufsize "$BUFSIZE" -g "$GOP" -bf 0 -look_ahead 0 -async 1 -c:a aac -b:a "$ABITRATE" -mpegts_flags +pat_pmt_at_frames+resend_headers -flush_packets 1 -max_muxing_queue_size 4096 -f mpegts pipe:1