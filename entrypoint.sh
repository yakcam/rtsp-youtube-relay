#!/bin/sh
# Restart supervisor for the ffmpeg RTSP→RTMP relay.
#
# Wraps a single ffmpeg invocation in a loop with capped exponential backoff,
# plus an outer `timeout` watchdog to recover from RTSP hangs (TCP up but no
# frames). See README.md and plan.md for the rationale behind every flag.

set -u

: "${RTSP_URL:?RTSP_URL must be set (see .env.example)}"
: "${YOUTUBE_STREAM_KEY:?YOUTUBE_STREAM_KEY must be set (see .env.example)}"

DELAY=5
MAX_DELAY=60
HEALTHY_RUN_SECONDS=120

while true; do
  START=$(date +%s)

  # Outer watchdog: if ffmpeg hangs (e.g. cheap camera stops sending frames
  # but TCP stays up), kill it after 10 minutes so the loop can restart it.
  timeout --signal=INT --kill-after=10s 600s \
  ffmpeg \
    -nostdin -loglevel info \
    -rtsp_transport tcp \
    -timeout 10000000 \
    -use_wallclock_as_timestamps 1 \
    -i "$RTSP_URL" \
    -f lavfi -i anullsrc=channel_layout=stereo:sample_rate=44100 \
    -map 0:v:0 -map 1:a:0 \
    -vf "scale=in_range=pc:out_range=tv,format=yuv420p" \
    -c:v libx264 -preset veryfast -tune zerolatency \
      -profile:v main -level 4.0 \
      -b:v 2500k -maxrate 2500k -bufsize 5000k \
      -g 50 -keyint_min 50 -sc_threshold 0 \
      -r 25 \
    -c:a aac -b:a 128k -ar 44100 -ac 2 \
    -f flv "rtmp://a.rtmp.youtube.com/live2/$YOUTUBE_STREAM_KEY"
  EXIT=$?

  END=$(date +%s)
  RAN=$((END - START))

  # If ffmpeg ran long enough to be considered healthy, reset backoff.
  # Otherwise double it (capped) so a wrong stream key / unreachable
  # camera doesn't hammer at 5s forever.
  if [ "$RAN" -gt "$HEALTHY_RUN_SECONDS" ]; then
    DELAY=5
  else
    DELAY=$((DELAY * 2))
    [ "$DELAY" -gt "$MAX_DELAY" ] && DELAY=$MAX_DELAY
  fi

  echo "ffmpeg exited (code=$EXIT, ran=${RAN}s); sleeping ${DELAY}s"
  sleep "$DELAY"
done
