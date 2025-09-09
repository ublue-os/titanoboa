#!/bin/bash
#
# Project Titanoboa
#
# Description: Create bootable ISOs from bootc container images.
#
# shellcheck disable=SC2317

{ return 0 2>/dev/null; } ||
    : 'Stop interpreting early if we sourced the script'

set -eo pipefail

# Enable verbose debugging
if [[ ${RUNNER_DEBUG:-0} -eq 1 || ${DEBUG:-0} -eq 1 ]]; then
    export PS4='+( ${BASH_SOURCE}:${LINENO} ): ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'
    set -x
fi

####### region PRIVATE_ENVIROMENTAL_VARS #######

_TITANOBOA_ROOT=$(dirname "$0")

_TITANOBOA_WORKDIR=${_TITANOBOA_ROOT}/work

_TITANOBOA_ISO_ROOTFS=${_TITANOBOA_WORKDIR}/iso-root

# Directory for the root filesystem of the live environment
_TITANOBOA_ROOTFS=${_TITANOBOA_WORKDIR}/rootfs

_TITANOBOA_CPU_ARCH=$(uname -m)

# Reference to a container image used as an external builder
_TITANOBOA_BUILDER_IMAGE= # Leave empty to be populated later on based on TITANOBOA_BUILDER_DISTRO

####### endregion PRIVATE_ENVIROMENTAL_VARS #######

#
#
#

####### region PUBLIC_ENVIROMENTAL_VARS #######

# Container image from which we extract the rootfs for the live environment.
# Example:
#   ghcr.io/ublue-os/bluefin:latest
TITANOBOA_LIVE_ENV_CTR_IMAGE=${TITANOBOA_LIVE_ENV_CTR_IMAGE:-}

TITANOBOA_BUILDER_DISTRO=${TITANOBOA_BUILDER_DISTRO:-fedora}

# Hook used for custom operations done in the rootfs before it is squashed.
TITANOBOA_HOOK_POSTROOTFS=${TITANOBOA_HOOK_POSTROOTFS:-}

# Hook used for custom operations done before the initramfs is generated.
TITANOBOA_HOOK_PREINITRAMFS=${TITANOBOA_HOOK_PREINITRAMFS:-}

# File with a list of Flatpak applications to install in the rootfs.
TITANOBOA_FLATPAKS_FILE=${TITANOBOA_FLATPAKS_FILE:-}

####### endregion PUBLIC_ENVIROMENTAL_VARS #######

#
#
#

# Set _TITANOBOA_BUILDER_IMAGE based on TITANOBOA_BUILDER_DISTRO
case ${TITANOBOA_BUILDER_DISTRO} in
fedora)
    _TITANOBOA_BUILDER_IMAGE=quay.io/fedora/fedora:latest
    ;;
centos)
    _TITANOBOA_BUILDER_IMAGE=ghcr.io/hanthor/centos-anaconda-builder:main
    ;;
almalinux-kitten)
    _TITANOBOA_BUILDER_IMAGE=quay.io/almalinux/almalinux:10-kitten
    ;;
almalinux)
    _TITANOBOA_BUILDER_IMAGE=quay.io/almalinux/almalinux:10
    ;;
*)
    echo "Unsupported builder distribution: ${TITANOBOA_BUILDER_DISTRO}"
    exit 1
    ;;
esac

#
#
#

####### region INNER_FUNCTIONS #######

# Show the configuration used to run Titanoboa. Should be the first thing to show.
_show_config() {
    echo "Using the following configuration:"
    echo "################################################################################"
    cat <<EOF | column -t
_TITANOBOA_WORKDIR := ${_TITANOBOA_WORKDIR:?}
_TITANOBOA_ROOTFS := ${_TITANOBOA_ROOTFS:?}
_TITANOBOA_CPU_ARCH := ${_TITANOBOA_CPU_ARCH:?}
TITANOBOA_LIVE_ENV_CTR_IMAGE := ${TITANOBOA_LIVE_ENV_CTR_IMAGE:?}
_TITANOBOA_BUILDER_IMAGE := ${_TITANOBOA_BUILDER_IMAGE:?}
_TITANOBOA_BUILDER_DISTRO := ${TITANOBOA_BUILDER_DISTRO:?}
EOF
    echo "################################################################################"
}

# Execute commands with podman using _TITANOBOA_ROOTFS as the rootfs
_chroot() {
    local _CHROOT_ARGS=${_CHROOT_ARGS:-}

    echo >&2 "TODO"
    return
    # shellcheck disable=SC2086
    sudo podman --transient-store run \
        --rm \
        -it \
        --privileged \
        --security-opt=label=type:unconfined_t \
        --rootfs ${_TITANOBOA_ROOTFS:?} \
        --tmpfs=/tmp:rw \
        --tmpfs=/run:rw \
        --volume="${_TITANOBOA_ROOT}/pkg":/bin/pkg:ro \
        ${_CHROOT_ARGS}

}

_chroot_builder() {
    echo >&2 "TODO"
}

####### endregion INNER_FUNCTIONS #######

#
#
#

####### region BUILD_STAGES #######

# Extract the root filesystem from a container image into _TITANOBOA_ROOTFS
#
# Arguments:
#   $1 - The container image to extract the root filesystem from.
_unpack_ctr_image_rootfs() {
    echo >&2 "Executing ${FUNCNAME[0]}..."

    local image=${1:?}
    local ctr_id

    echo >&2 "Creating container..."
    echo >&2 "  image=$image"
    ctr_id=$(sudo podman create --rm "$image" /bin/true)
    echo >&2 "Container created"
    echo >&2 "  ctr_id=$ctr_id"

    echo >&2 "Extracting root filesystem..."
    mkdir -p "$_TITANOBOA_ROOTFS"
    # shellcheck disable=SC2046
    podman export "$ctr_id" |
        env -v -- tar \
            --extract \
            --preserve-permissions \
            --xattrs-include='*' \
            --file - -C "$_TITANOBOA_ROOTFS"
    echo >&2 "Root filesystem extracted"

    echo >&2 "Removing leftover container..."
    podman rm "$ctr_id"
    echo >&2 "Removed leftover container"

    # Make /var/tmp be a tmpfs by symlinking to /tmp,
    # in order to make bootc work at runtime.
    echo >&2 "Symlinking /var/tmp to /tmp..."
    rm -rf "$_TITANOBOA_ROOTFS/var/tmp"
    ln -sr "$_TITANOBOA_ROOTFS/tmp" "$_TITANOBOA_ROOTFS/var/tmp"
    echo >&2 "Symlinked /var/tmp to /tmp"

    echo >&2 "Finished ${FUNCNAME[0]}"
}

# Clean the work directory
_clean() {
    echo >&2 "Executing ${FUNCNAME[0]}..."

    echo >&2 "Cleaning up work environment..."
    rm -rf "$(realpath "$_TITANOBOA_WORKDIR")"
    echo >&2 "Removed work directory"

    echo >&2 "Finished ${FUNCNAME[0]}"
}

# Prepare the work directory
_init_workplace() {
    echo >&2 "Executing ${FUNCNAME[0]}..."

    echo >&2 "Creating work directories..."
    mkdir -p \
        "$_TITANOBOA_WORKDIR" \
        "$_TITANOBOA_ISO_ROOTFS" \
        "$_TITANOBOA_ROOTFS"
    echo >&2 "Created work directories"

    echo >&2 "Finished ${FUNCNAME[0]}"
}

####### endregion BUILD_STAGES #######

#
#
#

main() {

    # Ensure we are running as root
    if [[ $(id -u) -ne 0 ]]; then
        echo >&2 "::error::Must be run as root."
        exit 1
    fi

    _show_config

    _clean

    _init_workplace

    _unpack_ctr_image_rootfs "$TITANOBOA_LIVE_ENV_CTR_IMAGE"

    echo >&2 "TODO"

    exit
}

main "$@"
