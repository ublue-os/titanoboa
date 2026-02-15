FROM quay.io/fedora/fedora:latest

ENV TITANOBOA_INSIDE_CONTAINER="true"

RUN dnf install -yq \
    bash \
    dosfstools \
    e2fsprogs \
    mtools \
    squashfs-tools \
    util-linux-core \
    xorriso \
    yq \
    ;
RUN mkdir -p /rootfs

COPY ./main.sh /app/bin/main.sh
COPY ./build_iso.sh /app/bin/build_iso.sh

VOLUME [ "/output", "/usr/lib/containers/storage" ]

CMD ["/app/bin/main.sh"]
