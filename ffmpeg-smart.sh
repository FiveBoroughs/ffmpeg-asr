#!/bin/bash
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

PROBE=$(ffprobe -v quiet -print_format json -show_streams "$URL" 2>/dev/null)
VCODEC=$(echo "$PROBE" | jq -r '.streams[0].codec_name')
FPS_FRAC=$(echo "$PROBE" | jq -r '.streams[0].r_frame_rate')
ABITRATE=$(echo "$PROBE" | jq -r '.streams[1].bit_rate // "128000"')

# Set video codec
if [[ "$VCODEC" == "hevc" ]]; then
    VCODEC_OUT="hevc_qsv"
else
    VCODEC_OUT="h264_qsv"
fi

# Bitrates
VBITRATE="8000000"
MAXRATE="10000000"
BUFSIZE="20000000"

# Calculate GOP for 1s keyframes (50/1 -> GOP=50)
if [[ "$FPS_FRAC" =~ ^([0-9]+)/([0-9]+)$ ]]; then
    GOP=$((${BASH_REMATCH[1]} / ${BASH_REMATCH[2]}))
else
    GOP=50
fi

exec ffmpeg -user_agent "$AGENT" -hwaccel qsv -hwaccel_output_format qsv -reconnect 1 -reconnect_at_eof 1 -reconnect_streamed 1 -reconnect_delay_max 30 -rw_timeout 15000000 -fflags +genpts+discardcorrupt -err_detect ignore_err -i "$URL" -c:v "$VCODEC_OUT" -preset fast -b:v "$VBITRATE" -maxrate "$MAXRATE" -bufsize "$BUFSIZE" -g "$GOP" -bf 0 -look_ahead 0 -async 1 -c:a aac -b:a "$ABITRATE" -mpegts_flags +pat_pmt_at_frames+resend_headers -flush_packets 1 -max_muxing_queue_size 4096 -f mpegts pipe:1