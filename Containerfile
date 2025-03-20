ARG BASE_IMAGE="ghcr.io/ublue-os/aurora:stable"
ARG DE_SESSION="kde"
FROM ${BASE_IMAGE}
RUN dnf5 install -y livesys-scripts && \
    systemctl enable livesys.service livesys-late.service && \
    sed -i "s/^livesys_session=.*/livesys_session=${DE_SESSION}/" /etc/sysconfig/livesys
