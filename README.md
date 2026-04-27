# RTSP → YouTube Live Relay

A small outbound-only Docker container that pulls an IP camera's RTSP feed,
re-encodes it to a YouTube-compatible H.264 + silent-AAC stream, and pushes
it via RTMP to YouTube Live. Nothing inbound is ever opened.

Designed to run alongside ZoneMinder on the same NAS but with no
dependency on it — the relay pulls directly from the camera.
Auto-reconnects on RTSP/RTMP drops and container restarts.

Pre-built image: [`yakcam/rtsp-youtube-relay`](https://hub.docker.com/r/yakcam/rtsp-youtube-relay)
on Docker Hub (`linux/amd64`). Built and published from `main` via
GitHub Actions.

## Setup

1. **Create the YouTube Live stream.** In YouTube Studio → *Go Live* →
   *Stream*, create a stream and copy the **Stream key** (not the URL).
   Recommend setting visibility to **Unlisted** for testing.

2. **Configure secrets.**

   ```sh
   cp .env.example .env
   # Edit .env, fill in RTSP_URL and YOUTUBE_STREAM_KEY
   chmod 600 .env
   ```

   Use the camera's **IP address**, not a hostname — DNS may not be
   available immediately on NAS boot, which would crash-loop the relay.

3. **Start the relay.**

   ```sh
   # Pull the published image and start
   docker compose pull
   docker compose up -d
   docker compose logs -f relay
   ```

   To build locally instead (e.g. during development):

   ```sh
   docker compose up -d --build
   ```

## Verification

In the logs, you should see ffmpeg's startup banner showing the detected
camera codec / resolution / framerate, then quiet running. Within ~30
seconds, YouTube Studio's *Live Control Room* should report a **GOOD**
connection, and the preview player will show the camera feed.

```sh
# Tail recent logs
docker compose logs --tail=200 -f relay

# Check for errors over the last day
docker compose logs --since 24h relay | grep -iE "error|warn"
```

Periodic reconnects are fine; constant crash-looping is not.

## Security

- **`.env` is gitignored.** It contains the camera password (in
  `RTSP_URL`) and your YouTube stream key. `chmod 600 .env` so other
  local users can't read it.
- **`docker inspect zm-stream-relay` exposes both secrets in plaintext**
  as env-var values. Treat the Docker socket on the NAS as
  root-equivalent. Don't paste `docker inspect` output or full container
  logs into public forums.
- **Don't raise ffmpeg's log level above `info`.** At `info`, the input
  URL is logged once at startup including the camera password — already
  visible to anyone who can run `docker logs`. Raising to `verbose` or
  `debug` adds further sensitive detail and is unnecessary for normal
  operation.
- The container drops all Linux capabilities, runs read-only, runs as a
  non-root user (UID 1000), and exposes no ports.

## Copyright warning

A 24/7 unattended public broadcast can accumulate copyright strikes on
your YouTube channel if the camera's audio (even though it's muted on
this relay) or the visible scene captures protected material — music
playing nearby, a TV in frame, etc. Run as **Unlisted** unless you've
thought this through. Strikes affect the whole channel, not just the
stream.

## Troubleshooting

### "Stream not starting" or "Bad" status in YouTube Studio

Check the logs first:

```sh
docker compose logs --tail=100 relay
```

- `Connection refused` / `Connection timed out` on the RTSP URL → camera
  unreachable. Verify with:

  ```sh
  ffmpeg -rtsp_transport tcp -i "$RTSP_URL" -t 10 -f null -
  ```

- `403 Forbidden` from YouTube → stream key is wrong or the YouTube
  stream was deleted. Re-copy the key from YouTube Studio.
- ffmpeg starts then exits within seconds, looping → check the input
  banner. If it shows `0 streams`, the RTSP path is wrong.

### Camera can only serve one RTSP client at a time

Older cameras sometimes limit themselves to one or two concurrent RTSP
sessions. If running ZoneMinder + this relay simultaneously kicks one
of them off, point the relay at ZoneMinder's restream endpoint instead
of the camera directly — change only `RTSP_URL` in `.env` and
`docker compose up -d` again.

### Hardware-accelerated encoding (Intel NAS, VAAPI)

Software x264 at `veryfast` uses very little CPU at 1280×960, so this
isn't usually needed. If you want to offload anyway:

1. Pass the GPU device into the container in `docker-compose.yml`:

   ```yaml
   devices:
     - /dev/dri:/dev/dri
   ```

2. In `entrypoint.sh`, replace the libx264 path with VAAPI. The
   colour-range conversion has to happen in the VAAPI filter chain, not
   the software `scale` filter:

   ```
   -vaapi_device /dev/dri/renderD128
   -vf "format=nv12,hwupload,scale_vaapi=out_range=tv"
   -c:v h264_vaapi -profile:v main -level 4.0
   -b:v 2500k -maxrate 2500k -bufsize 5000k
   -g 50 -keyint_min 50 -sc_threshold 0 -r 25
   ```

   Drop `-preset veryfast` and `-tune zerolatency` (libx264-only).

### Stream-copy is NOT a fallback

It's tempting to replace the libx264 re-encode with `-c:v copy` to save
CPU. **Don't** — for this camera. Its pixel format is `yuvj420p`
(full/PC range), and stream-copy would skip the
`yuvj420p`→`yuv420p` (limited/TV range) conversion. YouTube and most
players treat `yuvj420p` as `yuv420p` without range-mapping, producing a
washed-out / crushed image. The re-encode is what fixes that.
