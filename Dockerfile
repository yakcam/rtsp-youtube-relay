FROM alpine:3.20

# ffmpeg: the actual workload.
# coreutils: required for the --signal / --kill-after flags on `timeout` used
#            in entrypoint.sh; busybox's timeout doesn't support them.
RUN apk add --no-cache ffmpeg coreutils

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

USER 1000:1000

ENTRYPOINT ["/entrypoint.sh"]
