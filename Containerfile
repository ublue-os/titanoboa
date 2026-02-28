FROM docker.io/library/alpine:latest

ENV TITANOBOA_INSIDE_CONTAINER="true"

RUN for dep in \
    bash \
    coreutils \
    dosfstools \
    e2fsprogs \
    mtools \
    squashfs-tools \
    util-linux \
    xorriso \
    yq \
    ; do apk info -e "$dep" >/dev/null || apk add --no-cache "$dep"; done
RUN mkdir -p /rootfs

COPY ./main.sh /app/bin/main.sh
COPY ./build_iso.sh /app/bin/build_iso.sh

VOLUME [ "/output", "/usr/lib/containers/storage" ]

CMD ["/app/bin/main.sh"]
