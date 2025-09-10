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

####### region PUBLIC_ENVIROMENTAL_VARS #######

# Container image from which we extract the rootfs for the live environment.
# Example:
#   ghcr.io/ublue-os/bluefin:latest
TITANOBOA_LIVE_ENV_CTR_IMAGE=${TITANOBOA_LIVE_ENV_CTR_IMAGE:-}

TITANOBOA_INJECTED_CTR_IMAGE=${TITANOBOA_INJECTED_CTR_IMAGE:-$TITANOBOA_LIVE_ENV_CTR_IMAGE}

TITANOBOA_BUILDER_DISTRO=${TITANOBOA_BUILDER_DISTRO:-fedora}

# Hook used for custom operations done in the rootfs before it is squashed.
TITANOBOA_HOOK_POSTROOTFS=${TITANOBOA_HOOK_POSTROOTFS:-}

# Hook used for custom operations done before the initramfs is generated.
TITANOBOA_HOOK_PREINITRAMFS=${TITANOBOA_HOOK_PREINITRAMFS:-}

# File with a list of Flatpak applications to install in the rootfs.
TITANOBOA_FLATPAKS_FILE=${TITANOBOA_FLATPAKS_FILE:-}

TITANOBOA_TOGGLE_LIVESYS=${TITANOBOA_TOGGLE_LIVESYS:-1}

####### endregion PUBLIC_ENVIROMENTAL_VARS #######

#
#
#

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
_TITANOBOA_WORKDIR := ${_TITANOBOA_WORKDIR}
_TITANOBOA_ROOTFS := ${_TITANOBOA_ROOTFS}
_TITANOBOA_CPU_ARCH := ${_TITANOBOA_CPU_ARCH}
TITANOBOA_LIVE_ENV_CTR_IMAGE := ${TITANOBOA_LIVE_ENV_CTR_IMAGE}
TITANOBOA_INJECTED_CTR_IMAGE := ${TITANOBOA_INJECTED_CTR_IMAGE}
_TITANOBOA_BUILDER_IMAGE := ${_TITANOBOA_BUILDER_IMAGE}
_TITANOBOA_BUILDER_DISTRO := ${TITANOBOA_BUILDER_DISTRO}
TITANOBOA_PREINITRAMFS_HOOK := ${TITANOBOA_PREINITRAMFS_HOOK}
TITANOBOA_HOOK_POSTROOTFS := ${TITANOBOA_HOOK_POSTROOTFS}
TITANOBOA_FLATPAKS_FILE := ${TITANOBOA_FLATPAKS_FILE}
TITANOBOA_TOGGLE_LIVESYS := ${TITANOBOA_TOGGLE_LIVESYS}
EOF
    echo "################################################################################"
}

# Execute commands with podman using _TITANOBOA_ROOTFS as the rootfs.
#
# Environment variables:
#   PARAMETERS: Additional parameters to pass to podman before the rootfs flag.
#
# Arguments:
#   $1: Command to execute inside the rootfs.
#
# Usage:
#   _chroot /bin/bash -c "echo hello world"
#   _chroot /bin/bash <./script.sh
#   PARAMETERS="-v ./myscript.sh:/run/myscript.sh:ro,z" _chroot /run/myscript.sh
_chroot() {
    local PARAMETERS="$PARAMETERS"
    local args="$*"

    # shellcheck disable=SC2086
    podman --transient-store run \
        --rm \
        -i \
        --privileged \
        --net=host \
        --security-opt=label=type:unconfined_t \
        --env=DEBUG --env=RUNNER_DEBUG \
        --volume="${_TITANOBOA_ROOT}/pkg":/bin/pkg:ro \
        --tmpfs=/tmp:rw \
        --tmpfs=/run:rw \
        ${PARAMETERS:-} \
        --rootfs "$(realpath ${_TITANOBOA_ROOTFS:?})" \
        $args
}

# Execute commands within a container with the liveiso rootfs mounted as a subdirectory.
_chroot_builder() {
    local PARAMETERS="$PARAMETERS"
    local args="$*"

    # shellcheck disable=SC2086
    podman --transient-store run \
        --rm \
        -i \
        --privileged \
        --net=host \
        --security-opt=label=disable \
        --volume="${_TITANOBOA_ROOT}/pkg":/bin/pkg:ro \
        --tmpfs=/tmp:rw \
        --tmpfs=/run:rw \
        --volume="${_TITANOBOA_WORKDIR}":/run/work:rw \
        ${PARAMETERS:-} \
        ${_TITANOBOA_BUILDER_IMAGE:?} $args
}

####### endregion INNER_FUNCTIONS #######

#
#
#

####### region BUILD_STAGES #######

# Extract the root filesystem from a container image into _TITANOBOA_ROOTFS
_unpack_ctr_image_rootfs() {
    echo >&2 "Executing ${FUNCNAME[0]}..."

    local ctr_id

    echo >&2 "Creating container..."
    echo >&2 "  TITANOBOA_LIVE_ENV_CTR_IMAGE=$TITANOBOA_LIVE_ENV_CTR_IMAGE"
    ctr_id=$(sudo podman create --rm "$TITANOBOA_LIVE_ENV_CTR_IMAGE" /bin/true)
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

# Hook ran before setting initramfs.
_hook_preinitramfs() {

    echo >&2 "Executing ${FUNCNAME[0]}..."

    if [ -n "$TITANOBOA_PREINITRAMFS_HOOK" ]; then
        echo >&2 "Running preinitramfs hook..."
        echo >&2 "  TITANOBOA_PREINITRAMFS_HOOK=$TITANOBOA_PREINITRAMFS_HOOK"
        PARAMETERS="--volume=$TITANOBOA_PREINITRAMFS_HOOK:/run/hook.sh:ro,z" \
            _chroot /bin/sh -c "/run/hook.sh"
        echo >&2 "Finished running preinitramfs hook"
    fi

    echo >&2 "Finished ${FUNCNAME[0]}"
}

# Build the initramfs image.
_build_initramfs() {

    echo >&2 "Executing ${FUNCNAME[0]}..."

    echo >&2 "Building initramfs image..."
    PARAMETERS="-v $_TITANOBOA_WORKDIR:/run/workdir:rw" \
        _chroot /bin/pkg setup-initramfs /run/workdir/initramfs.img
    echo >&2 "Finished building initramfs image"

    echo >&2 "Finished ${FUNCNAME[0]}"
}

# Install flatpaks into the live environment rootfs.
_rootfs_include_flatpaks() {

    echo >&2 "Executing ${FUNCNAME[0]}..."

    echo >&2 "Installing flatpaks..."
    if [[ -n $TITANOBOA_FLATPAKS_FILE ]]; then
        echo >&2 "  TITANOBOA_FLATPAKS_FILE=$TITANOBOA_FLATPAKS_FILE"
        PARAMETERS="--volume=$TITANOBOA_FLATPAKS_FILE:/run/flatpaks.txt:ro,z" \
            _chroot /bin/bash <<RUNEOF
            set -euxo pipefail
            mkdir -p /var/lib/flatpak
            pkg install flatpak
            flatpak remote-add --if-not-exists flathub "https://dl.flathub.org/repo/flathub.flatpakrepo"
            grep -v "#.*" /run/flatpaks.txt |
                sort --reverse |
                xargs "-i{}" -d "\n" sh -c "flatpak remote-info --arch=${_TITANOBOA_CPU_ARCH} --system flathub {} &>/dev/null && flatpak install --noninteractive -y {}" || true
RUNEOF
    fi
    echo >&2 "Finished installing flatpaks"

    echo >&2 "Finished ${FUNCNAME[0]}"
}

# Setup the live environment (ex.: create an passwordless user)
_rootfs_setup_livesys() {

    echo >&2 "Executing ${FUNCNAME[0]}..."

    if [[ $TITANOBOA_TOGGLE_LIVESYS = 1 ]]; then
        echo >&2 "Setting up livesys..."
        echo >&2 "  TITANOBOA_TOGGLE_LIVESYS=$TITANOBOA_TOGGLE_LIVESYS"
        _chroot /bin/pkg setup-livesys
        echo >&2 "Finished setting up livesys"
    fi

    echo >&2 "Finished ${FUNCNAME[0]}"
}

# Inject a container image into the rootfs container storage.
_rootfs_include_container() {
    echo >&2 "Executing ${FUNCNAME[0]}..."

    echo >&2 "Including container..."
    echo >&2 "  TITANOBOA_INJECTED_CTR_IMAGE=$TITANOBOA_INJECTED_CTR_IMAGE"
    _chroot /bin/bash <<RUNEOF
    set -euxo pipefail
    mkdir -p /var/lib/containers/storage
    podman pull $TITANOBOA_INJECTED_CTR_IMAGE
    pkg install fuse-overlayfs
RUNEOF
    echo >&2 "Finished including container"

    echo >&2 "Finished ${FUNCNAME[0]}"
}

# Hook ran after the rootfs is setup.
_hook_postrootfs() {

    echo >&2 "Executing ${FUNCNAME[0]}..."

    if [ -n "$TITANOBOA_POSTROOTFS_HOOK" ]; then
        echo >&2 "Running postrootfs hook..."
        echo >&2 "  TITANOBOA_POSTROOTFS_HOOK=$TITANOBOA_POSTROOTFS_HOOK"
        PARAMETERS="--volume=$TITANOBOA_POSTROOTFS_HOOK:/run/hook.sh:ro,z" \
            _chroot /bin/sh -c "/run/hook.sh"
        echo >&2 "Finished running postrootfs hook"
    fi

    echo >&2 "Finished ${FUNCNAME[0]}"
}

# Remove lefovers from bootc/ostree
_rootfs_clean_sysroot() {
    echo >&2 "Executing ${FUNCNAME[0]}..."

    _chroot /bin/sh <<RUNEOF
    rm -rf /sysroot /ostree
RUNEOF

    echo >&2 "Finished ${FUNCNAME[0]}"
}

# Build the squashfs.img where we store the rootfs of the live environment
_build_squashfs() {
    echo >&2 "Executing ${FUNCNAME[0]}..."

    echo >&2 "Building squashfs..."
    _chroot_builder /bin/bash <<RUNEOF
    pkg install mksquashfs
    mksquashfs /run/work/$(basename "$_TITANOBOA_ROOTFS") /run/work/squashfs.img -all-root -noappend
RUNEOF
    echo >&2 "Finished building squashfs"

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

    _unpack_ctr_image_rootfs

    _hook_preinitramfs

    _build_initramfs

    _rootfs_include_flatpaks

    _rootfs_setup_livesys

    _rootfs_include_container

    _hook_postrootfs

    _rootfs_clean_sysroot

    _build_squashfs

    echo >&2 "TODO"

    exit
}

main "$@"
