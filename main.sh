#!/bin/bash
#
# Project Titanoboa
#
# Description: Create bootable ISOs from bootc container images.
#
# shellcheck disable=SC2317

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

TITANOBOA_TOGGLE_POLKIT=${TITANOBOA_TOGGLE_POLKIT:-1}

TITANOBOA_TOGGLE_LIVESYS=${TITANOBOA_TOGGLE_LIVESYS:-1}

# List of extra kernel arguments to pass to the live iso grub config.
TITANOBOA_EXTRA_KARGS=${TITANOBOA_EXTRA_KARGS:-}

####### endregion PUBLIC_ENVIROMENTAL_VARS #######

#
#
#

####### region PRIVATE_ENVIROMENTAL_VARS #######

_TITANOBOA_ROOT=$(realpath -s "$(dirname "$0")")

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

# Show the configuration used to run Titanoboa and dump it into an .titanoboa.env file.
# Should be the first thing to show.
_setup_config() {
    mkdir -p "${_TITANOBOA_WORKDIR}" # Ensure workdir exists before dumping conf
    echo "Using the following configuration:"
    echo "################################################################################"
    {
        for _key in ${!TITANOBOA_*} ${!_TITANOBOA_*}; do
            echo "${_key}=${!_key}"
        done
    } | tee "${_TITANOBOA_WORKDIR}"/.titanoboa.env
    echo "################################################################################"
}

# Execute commands within a container using a directory as rootfs.
#
# Usage:
#   _chroot /bin/bash -c "echo hello world"
#   _chroot /bin/bash <./script.sh
#   _chroot --volume=./myscript.sh:/run/myscript.sh:ro,z /run/myscript.sh
_chroot() {
    # shellcheck disable=SC2086
    podman --transient-store run \
        --rm \
        -i \
        --privileged \
        --net=host \
        --security-opt=label=disable \
        --env=DEBUG --env=RUNNER_DEBUG \
        --volume="${_TITANOBOA_ROOT}/pkg":/bin/pkg:ro \
        --env-file="${_TITANOBOA_WORKDIR}"/.titanoboa.env \
        --tmpfs=/tmp:rw \
        --tmpfs=/run:rw \
        --volume="${_TITANOBOA_WORKDIR}":/run/work:rw \
        "$@"
}

# Execute commands with podman using _TITANOBOA_ROOTFS as the rootfs.
#
# Environment variables:
#   PARAMETERS: Additional parameters to pass to podman before the rootfs flag.
#
# Arguments:
#   $*: Command to execute inside the rootfs.
#
# Usage:
#   _chroot_rootfs /bin/bash -c "echo hello world"
#   _chroot_rootfs /bin/bash <./script.sh
#   PARAMETERS="-v ./myscript.sh:/run/myscript.sh:ro,z" _chroot_rootfs /run/myscript.sh
_chroot_rootfs() {
    # shellcheck disable=SC2086
    _chroot ${PARAMETERS} --rootfs "$_TITANOBOA_ROOTFS" "$@"
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
            _chroot_rootfs /bin/sh -c "/run/hook.sh"
        echo >&2 "Finished running preinitramfs hook"
    fi

    echo >&2 "Finished ${FUNCNAME[0]}"
}

# Build the initramfs image.
_build_initramfs() {

    echo >&2 "Executing ${FUNCNAME[0]}..."

    echo >&2 "Building initramfs image..."
    _chroot_rootfs /bin/pkg setup-initramfs /run/work/initramfs.img
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
            _chroot_rootfs /bin/bash <<RUNEOF
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

# Setup polkit.
_rootfs_setup_polkit() {
    echo >&2 "Executing ${FUNCNAME[0]}..."

    if [[ $TITANOBOA_TOGGLE_POLKIT = 1 ]]; then
        echo >&2 "Setting up polkit..."
        echo >&2 "  TITANOBOA_TOGGLE_POLKIT=$TITANOBOA_TOGGLE_POLKIT"
        install -D -m 0644 \
            "$_TITANOBOA_ROOT"/src/polkit-1/rules.d/*.rules \
            -t "$_TITANOBOA_ROOTFS"/etc/polkit-1/rules.d
        echo >&2 "Finished setting up polkit"
    fi

    echo >&2 "Finished ${FUNCNAME[0]}"
}

# Setup the live environment (ex.: create an passwordless user)
_rootfs_setup_livesys() {

    echo >&2 "Executing ${FUNCNAME[0]}..."

    if [[ $TITANOBOA_TOGGLE_LIVESYS = 1 ]]; then
        echo >&2 "Setting up livesys..."
        echo >&2 "  TITANOBOA_TOGGLE_LIVESYS=$TITANOBOA_TOGGLE_LIVESYS"
        _chroot_rootfs /bin/pkg setup-livesys
        echo >&2 "Finished setting up livesys"
    fi

    echo >&2 "Finished ${FUNCNAME[0]}"
}

# Inject a container image into the rootfs container storage.
_rootfs_include_container() {
    echo >&2 "Executing ${FUNCNAME[0]}..."

    echo >&2 "Including container..."
    echo >&2 "  TITANOBOA_INJECTED_CTR_IMAGE=$TITANOBOA_INJECTED_CTR_IMAGE"
    _chroot_rootfs /bin/bash <<RUNEOF
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
            _chroot_rootfs /bin/sh -c "/run/hook.sh"
        echo >&2 "Finished running postrootfs hook"
    fi

    echo >&2 "Finished ${FUNCNAME[0]}"
}

# Remove lefovers from bootc/ostree
_rootfs_clean_sysroot() {
    echo >&2 "Executing ${FUNCNAME[0]}..."

    _chroot_rootfs /bin/sh <<RUNEOF
    rm -rf /sysroot /ostree
RUNEOF

    echo >&2 "Finished ${FUNCNAME[0]}"
}

# Relabel files in the rootfs.
_rootfs_selinux_fix() {
    echo >&2 "Executing ${FUNCNAME[0]}..."

    echo >&2 "Fixing SELinux..."
    _chroot_rootfs /bin/bash <<RUNEOF
    if [[ ! -f /usr/bin/setfiles ]]; then exit 0; fi
    set -exuo pipefail
    cd /run/work/$(basename "$_TITANOBOA_ROOTFS")
    /usr/bin/setfiles -F -r . /etc/selinux/targeted/contexts/files/file_contexts . || :
    shopt -s extglob
    /usr/bin/chcon --user=system_u --recursive !(proc|dev|sys)
RUNEOF
    echo >&2 "Finished fixing SELinux"

    echo >&2 "Finished ${FUNCNAME[0]}"
}

# Remove images from container storage if we are running in CI.
# It runs if the environment variable CI is set to "true".
_ci_cleanup() {
    echo >&2 "Executing ${FUNCNAME[0]}..."

    if [[ $CI == true ]]; then
        echo >&2 "Cleaning up container images..."
        podman rmi --force "$TITANOBOA_INJECTED_CTR_IMAGE" "$TITANOBOA_LIVE_ENV_CTR_IMAGE" || :
        echo >&2 "Finished cleaning up container images"
    fi

    echo >&2 "Finished ${FUNCNAME[0]}"
}

# Build the squashfs.img where we store the rootfs of the live environment
_build_squashfs() {
    echo >&2 "Executing ${FUNCNAME[0]}..."

    echo >&2 "Building squashfs..."
    _chroot "$_TITANOBOA_BUILDER_IMAGE" /bin/bash <<RUNEOF
    pkg install mksquashfs
    mksquashfs /run/work/$(basename "$_TITANOBOA_ROOTFS") /run/work/squashfs.img -all-root -noappend
RUNEOF
    echo >&2 "Finished building squashfs"

    echo >&2 "Finished ${FUNCNAME[0]}"
}

# Expand grub templace, according to the image os-release.
_process_grub_template() {
    echo >&2 "Executing ${FUNCNAME[0]}..."

    echo >&2 "Expanding grub template..."

    local _os_release_file \
        _grub_tmpl \
        _dest \
        PRETTY_NAME

    _os_release_file="$_TITANOBOA_ROOTFS/usr/lib/os-release"
    _grub_tmpl="$_TITANOBOA_ROOT"/src/grub.cfg.tmpl
    _dest="$_TITANOBOA_ISO_ROOTFS"/boot/grub/grub.cfg

    mkdir -p "$(dirname "$_dest")"
    # shellcheck source=/dev/null
    PRETTY_NAME="$(source "$_os_release_file" >/dev/null && echo "${PRETTY_NAME/ (*)/}")"
    sed \
        -e "s|@PRETTY_NAME@|${PRETTY_NAME}|g" \
        -e "s|@EXTRA_KARGS@|${TITANOBOA_EXTRA_KARGS}|g" \
        "$_grub_tmpl" >"$_dest"

    echo >&2 "Finished expanding grub template"

    echo >&2 "Finished ${FUNCNAME[0]}"
}

# Move generated files to its destination in the ISO root filesystem.
_iso_organize() {
    echo >&2 "Executing ${FUNCNAME[0]}..."

    echo >&2 "Organizing ISO filesystem..."
    mkdir -p "$_TITANOBOA_ISO_ROOTFS"/boot/grub "$_TITANOBOA_ISO_ROOTFS"/LiveOS
    cp "$_TITANOBOA_ROOTFS"/lib/modules/*/vmlinuz "$_TITANOBOA_ISO_ROOTFS"/boot
    cp "$_TITANOBOA_WORKDIR"/initramfs.img "$_TITANOBOA_ISO_ROOTFS"/boot
    # Hardcoded on the dmsquash-live source code unless specified otherwise via kargs
    # https://github.com/dracut-ng/dracut-ng/blob/0ffc61e536d1193cb837917d6a283dd6094cb06d/modules.d/90dmsquash-live/dmsquash-live-root.sh#L23
    cp "$_TITANOBOA_WORKDIR"/squashfs.img "$_TITANOBOA_ISO_ROOTFS"/LiveOS/squashfs.img
    echo >&2 "Finished organizing ISO filesystem"

    echo >&2 "Finished ${FUNCNAME[0]}"
}

_build_iso() {
    echo >&2 "Executing ${FUNCNAME[0]}..."

    echo >&2 "Building ISO..."
    if systemd-detect-virt -cq; then
        echo >&2 "::error::Running in a nested container is not supported."
        return 1
    fi
    _chroot quay.io/fedora/fedora:latest /bin/bash <<'RUNEOF'
    set -euxo pipefail

    WORKDIR=/run/work
    ISOROOT=/run/work/$(basename "${_TITANOBOA_ISO_ROOTFS}")

    # Install dependencies
    pkg install -y grub2 grub2-efi grub2-tools grub2-tools-extra xorriso shim dosfstools
    _unam=$(uname -m)
    if [[ $_unam == x86_64 ]]; then
        pkg install grub2-efi-x64-modules grub2-efi-x64-cdboot grub2-efi-x64
    elif [[ $_unam == aarch64 ]]; then
        pkg install grub2-efi-aa64-modules
    fi

    mkdir -p $ISOROOT/EFI/BOOT
    # ARCH_SHORT needs to be uppercase
    ARCH_SHORT="$(uname -m | sed 's/x86_64/x64/g' | sed 's/aarch64/aa64/g')"
    ARCH_32="$(uname -m | sed 's/x86_64/ia32/g' | sed 's/aarch64/arm/g')"
    cp -avf /boot/efi/EFI/fedora/. $ISOROOT/EFI/BOOT
    cp -avf $ISOROOT/boot/grub/grub.cfg $ISOROOT/EFI/BOOT/BOOT.conf
    cp -avf $ISOROOT/boot/grub/grub.cfg $ISOROOT/EFI/BOOT/grub.cfg
    cp -avf /boot/grub*/fonts/unicode.pf2 $ISOROOT/EFI/BOOT/fonts
    cp -avf $ISOROOT/EFI/BOOT/shim${ARCH_SHORT}.efi "$ISOROOT/EFI/BOOT/BOOT${ARCH_SHORT^^}.efi"
    cp -avf $ISOROOT/EFI/BOOT/shim.efi "$ISOROOT/EFI/BOOT/BOOT${ARCH_32}.efi"

    ARCH_GRUB="$(uname -m | sed 's/x86_64/i386-pc/g' | sed 's/aarch64/arm64-efi/g')"
    ARCH_OUT="$(uname -m | sed 's/x86_64/i386-pc-eltorito/g' | sed 's/aarch64/arm64-efi/g')"
    ARCH_MODULES="$(uname -m | sed 's/x86_64/biosdisk/g' | sed 's/aarch64/efi_gop/g')"

    grub2-mkimage -O $ARCH_OUT -d /usr/lib/grub/$ARCH_GRUB -o $ISOROOT/boot/eltorito.img -p /boot/grub iso9660 $ARCH_MODULES
    grub2-mkrescue -o $WORKDIR/efiboot.img

    EFI_BOOT_MOUNT=$(mktemp -d)
    mount $WORKDIR/efiboot.img $EFI_BOOT_MOUNT
    cp -r $EFI_BOOT_MOUNT/boot/grub $ISOROOT/boot/
    umount $EFI_BOOT_MOUNT
    rm -rf $EFI_BOOT_MOUNT

    # https://github.com/FyraLabs/katsu/blob/1e26ecf74164c90bc24299a66f8495eb2aef4845/src/builder.rs#L145
    EFI_BOOT_PART=$(mktemp -d)
    fallocate $WORKDIR/efiboot.img -l 25M
    mkfs.msdos -v -n EFI $WORKDIR/efiboot.img
    mount $WORKDIR/efiboot.img $EFI_BOOT_PART
    mkdir -p $EFI_BOOT_PART/EFI/BOOT
    cp -dRvf $ISOROOT/EFI/BOOT/. $EFI_BOOT_PART/EFI/BOOT
    umount $EFI_BOOT_PART

    ARCH_SPECIFIC=()
    if [ "$(uname -m)" = "x86_64" ] ; then
        ARCH_SPECIFIC=("--grub2-mbr" "/usr/lib/grub/i386-pc/boot_hybrid.img")
    fi

    xorrisofs \
        -R \
        -V bluefin_boot \
        -partition_offset 16 \
        -appended_part_as_gpt \
        -append_partition 2 C12A7328-F81F-11D2-BA4B-00A0C93EC93B \
        $WORKDIR/efiboot.img \
        -iso_mbr_part_type EBD0A0A2-B9E5-4433-87C0-68B6B72699C7 \
        -c boot.cat --boot-catalog-hide \
        -b boot/eltorito.img \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        --grub2-boot-info \
        -eltorito-alt-boot \
        -e \
        --interval:appended_partition_2:all:: \
        -no-emul-boot \
        -vvvvv \
        -iso-level 3 \
        -o /run/work/output.iso \
        "${ARCH_SPECIFIC[@]}" \
        $ISOROOT
RUNEOF
    echo >&2 "Finished building ISO"

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

    _clean

    _setup_config

    _init_workplace

    _unpack_ctr_image_rootfs

    _hook_preinitramfs

    _build_initramfs

    _rootfs_include_flatpaks

    _rootfs_setup_polkit

    _rootfs_setup_livesys

    _rootfs_include_container

    _hook_postrootfs

    _rootfs_clean_sysroot

    _rootfs_selinux_fix

    _ci_cleanup

    _build_squashfs

    _process_grub_template

    _iso_organize

    _build_iso

    echo >&2 "TODO"

    exit
}

{ return 0 2>/dev/null; } ||
    : 'Stop interpreting early if we sourced the script'

set -eo pipefail

main "$@"
