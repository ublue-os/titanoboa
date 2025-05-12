set unstable := true
PODMAN := which("podman") || require("podman-remote")
workdir := env("TITANOBOA_WORKDIR", "work")
isoroot := env("TITANOBOA_ISO_ROOT", "work/iso-root")

### HOOKS SCRIPT PATHS ###
# Path to scripts used as hooks in between steps, used in 'hook-*' recipes.
# Must follow the naming convention HOOK_<recipe name without 'hook_' prefix>

# Hook used for custom operations done in the rootfs before it is squashed.
HOOK_post_rootfs := ''
##########################

### UTILS ###
_ci_grouping := '''
if [[ -n "${CI:-}" ]]; then
    echo "::group::${BASH_SOURCE[0]##*/} step"
    trap 'echo ::endgroup::' EXIT
fi
'''
[private]
just := just_executable() + " -f " + source_file()

[private]
git_root := source_dir()
rootfs := workdir/"rootfs"

chroot_function := '
function chroot(){
    local command="$1"
    shift
    local args="$*"
    ' + PODMAN + ' run --rm -it \
    --privileged \
    --security-opt label=type:unconfined_t \
    $args \
    --volume ' + git_root + ':/app \
    --rootfs ' + git_root/rootfs + ' \
    /usr/bin/bash -c "$command"
}'

builder_function := '
function builder(){
    local command="$1"
    shift
    local args="$*"
    ' + PODMAN + ' run --rm -it \
    --privileged \
    --security-opt label=disable \
    --volume ' + git_root + ':/app \
    quay.io/fedora/fedora:latest \
    /usr/bin/bash -c "$command" $args
}'

compress_dependencies := '
function compress_dependencies(){
    local MISSING=()
    local RPMS=(
        erofs-utils
        squashfs-tools
    )
    if ! command -v rpm >/dev/null; then
        echo "1"
        return
    fi
    for rpm in "${RPMS[@]}"; do
        if ! rpm -q $rpm >/dev/null; then
            MISSING+=($rpm)
        fi
    done
    echo "${#MISSING[@]}"
}'
iso_dependencies := '
function iso_dependencies(){
    local MISSING=()
    local RPMS=(
        dosfstools
        grub2
        grub2-efi
        grub2-tools
        grub2-tools-extra
        shim
        xorriso
    )
    if [[ "$(uname -m)" == "x86_64" ]]; then
        RPMS+=(
            grub2-efi-x64
            grub2-efi-x64-cdboot
            grub2-efi-x64-modules
        )
    elif [[ "$(uname -m)" == "aarch64" ]]; then
        RPMS+=(grub2-efi-aa64-modules)
    fi
    if ! command -v rpm >/dev/null; then
        echo "1"
        return
    fi
    for rpm in "${RPMS[@]}"; do
        if ! rpm -q $rpm >/dev/null; then
            MISSING+=($rpm)
        fi
    done
    echo "${#MISSING[@]}"
}'
default_image := "ghcr.io/ublue-os/bluefin:lts"
#############

# Default
@default:
    {{ just }} --list

init-work:
    @echo "{{ style('command') }}Creating Work Directories...{{ NORMAL }}" >&2
    mkdir -p {{ workdir }}
    mkdir -p {{ isoroot }}
    mkdir -p {{ rootfs }}

rootfs image=default_image:
    #!/usr/bin/env bash
    {{ _ci_grouping }}
    set -xeuo pipefail
    # Pull and Extract Filesystem
    {{ PODMAN }} image exists {{ image }} || {{ PODMAN }} pull {{ image }}
    ctr="$({{ PODMAN }} create --rm {{ image }} /usr/bin/bash)" && trap "{{ PODMAN }} rm $ctr" EXIT
    {{ PODMAN }} export $ctr | tar -xf - -C {{ rootfs }}

    # Make /var/tmp be a tmpfs by symlinking to /tmp,
    # in order to make bootc work at runtime.
    rm -rf {{ rootfs }}/var/tmp
    ln -sr {{ rootfs }}/tmp {{ rootfs }}/var/tmp

initramfs:
    #!/usr/bin/env bash
    {{ _ci_grouping }}
    {{ chroot_function }}
    set -xeuo pipefail
    CMD='set -xeuo pipefail
    dnf install -y dracut dracut-live
    INSTALLED_KERNEL=$(rpm -q kernel-core --queryformat "%{evr}.%{arch}" | tail -n 1)
    mkdir -p $(realpath /root)
    export DRACUT_NO_XATTR=1
    dracut --zstd --reproducible --no-hostonly --kver "$INSTALLED_KERNEL" --add "dmsquash-live dmsquash-live-autooverlay" --force /app/{{ workdir }}/initramfs.img |& grep -v -e "Operation not supported"'
    chroot "$CMD"

rootfs-setuid:
    #!/usr/bin/env bash
    {{ _ci_grouping }}
    {{ chroot_function }}
    set -xeuo pipefail
    CMD='set -eoux pipefail
    for file in /usr/bin/sudo /usr/lib/polkit-1/polkit-agent-helper-1 /usr/bin/passwd /usr/bin/pkexec /usr/bin/fusermount3; do
        chmod u+s $file
    done'
    chroot "$CMD"

rootfs-include-container $container_image=default_image image=default_image:
    #!/usr/bin/env bash
    {{ _ci_grouping }}
    {{ chroot_function }}
    set -xeuo pipefail
    : ${container_image:={{ image }}}
    CMD="set -eoux pipefail
    mkdir -p /var/lib/containers/storage
    podman pull ${container_image}
    dnf install -y fuse-overlayfs"
    chroot "$CMD"

rootfs-include-flatpaks FLATPAKS_FILE="src/flatpaks.example.txt":
    #!/usr/bin/env bash
    {{ _ci_grouping }}
    {{ chroot_function }}
    if [[ -z "{{ FLATPAKS_FILE }}" || "{{ FLATPAKS_FILE }}" =~ ^none$|^NONE$ ]]; then
        exit 0
    elif [[ ! -f "{{ FLATPAKS_FILE }}" ]]; then
        echo "{{ style('error') }}ERROR[rootfs-include-flatpaks]{{ NORMAL }}: Flatpak file does not exist. Check right path. Current Path: {{ FLATPAKS_FILE }}" >&2
        exit 1
    fi
    set -eoux pipefail
    CMD='set -eoux pipefail
    mkdir -p /var/lib/flatpak
    dnf install -y flatpak
    flatpak remote-add --if-not-exists flathub "https://dl.flathub.org/repo/flathub.flatpakrepo"
    grep -v "#.*" /flatpak/$(basename {{ FLATPAKS_FILE }}) | sort --reverse | xargs "-i{}" -d "\n" sh -c "flatpak remote-info --system flathub app/{}/$(uname -m)/stable &>/dev/null && flatpak install --noninteractive -y {}" || true
    flatpak build-update-repo /var/lib/flatpak/repo'
    chroot "$CMD" --volume "$(realpath "$(dirname {{ FLATPAKS_FILE }})")":/flatpak
    rm -rf {{ rootfs }}/flatpak
    mv {{ rootfs }}/var/lib/flatpak {{ rootfs }}/flatpak
    ln -sr {{ rootfs }}/flatpak {{ rootfs }}/var/lib/flatpak

rootfs-include-polkit polkit="1":
    #!/usr/bin/env bash
    {{ _ci_grouping }}
    if [[ "{{ polkit }}" -eq "0" ]]; then
        exit 0
    fi
    set -xeuo pipefail
    install -Dpm0644 -t "{{ rootfs }}/etc/polkit-1/rules.d/" {{ git_root }}/src/polkit-1/rules.d/*.rules

rootfs-install-livesys-scripts livesys="1":
    #!/usr/bin/env bash
    {{ _ci_grouping }}
    if [[ "{{ livesys }}" -eq "0" ]]; then
        exit 0
    fi
    {{ chroot_function }}
    set -xeuo pipefail
    CMD='set -xeuo pipefail
    dnf="$({ which dnf5 || which dnf; } 2>/dev/null)"
    $dnf install -y livesys-scripts

    # Determine desktop environment. Must match one of /usr/libexec/livesys/sessions.d/livesys-{desktop_env}
    desktop_env=""
    _session_file="$(find /usr/share/wayland-sessions/ /usr/share/xsessions \
        -maxdepth 1 -type f -not -name '*gamescope*.desktop' -and -name '*.desktop' -printf '%P' -quit)"
    case $_session_file in
    budgie*)        desktop_env=budgie;;
    cosmic*)        desktop_env=cosmic;;
    gnome*)         desktop_env=gnome ;;
    plasma.desktop) desktop_env=kde   ;;
    sway*)          desktop_env=sway  ;;
    xfce.desktop)   desktop_env=xfce  ;;
    *)
        echo "{{ style('error') }}ERROR[rootfs-install-livesys-scripts]{{ NORMAL }}: no matching desktop enviroment found"\
            " at /usr/share/wayland-sessions/ /usr/share/xsessions";
        exit 1
    ;;
    esac && unset -v _session_file
    sed -i "s/^livesys_session=.*/livesys_session=${desktop_env}/" /etc/sysconfig/livesys

    # Enable services
    systemctl enable livesys.service livesys-late.service

    # Set default time zone to prevent oddities with KDE clock
    echo "C /var/lib/livesys/livesys-session-extra 0755 root root - /usr/share/factory/var/lib/livesys/livesys-session-extra" > \
      /usr/lib/tmpfiles.d/livesys-session-extra.conf'
    chroot "$CMD"
    install -D -m 0644 src/livesys-session-extra {{ rootfs }}/usr/share/factory/var/lib/livesys/livesys-session-extra

# Hook used for custom operations done in the rootfs before it is squashed.
# Meant to be used in a GH action.
[private]
hook-post-rootfs hook=HOOK_post_rootfs:
    #!/usr/bin/env bash
    {{ _ci_grouping }}
    {{ chroot_function }}
    {{ if hook == '' { 'exit 0' } else { '' } }}
    set -xeuo pipefail
    chroot "$(cat {{ hook }})"

rootfs-clean-sysroot:
    #!/usr/bin/env bash
    {{ _ci_grouping }}
    {{ chroot_function }}
    CMD='
    if [[ -d /app ]]; then
        rm -rf /sysroot
    fi'
    set -eoux pipefail
    chroot "$CMD"

squash $fs_type="squashfs":
    #!/usr/bin/env bash
    {{ _ci_grouping }}
    {{ compress_dependencies }}
    {{ builder_function }}
    BUILDER="$(compress_dependencies)"
    set -xeuo pipefail
    if [[ "$fs_type" == "erofs" ]]; then
        CMD='mkfs.erofs -d0 --quiet --all-root -zlz4hc,6 -Eall-fragments,fragdedupe=inode -C1048576 $1/squashfs.img $0'
    elif [[ "$fs_type" == "squashfs" ]]; then
        CMD='mksquashfs $0 $1/squashfs.img -all-root -noappend'
    fi
    if ! (( BUILDER )); then
        bash -c "$CMD" "$(realpath {{ rootfs }})" "$(realpath {{ workdir }})"
    else
        if [[ "$fs_type" == "erofs" ]]; then
            CMD="dnf install -y erofs-utils;$CMD"
        elif [[ "$fs_type" == "squashfs" ]]; then
            CMD="dnf install -y squashfs-tools;$CMD"
        fi
        builder "$CMD" "/app/{{ rootfs }}" "/app/{{ workdir }}"
    fi

# Expand grub templace, according to the image os-release.
process-grub-template $extra_kargs="NONE":
    #!/usr/bin/env bash
    {{ _ci_grouping }}
    set -xeuo pipefail
    kargs=()
    IFS=',' read -r -a kargs <<< "$extra_kargs"
    if [[ "$extra_kargs" == "NONE" ]]; then
        kargs=()
    fi

    OS_RELEASE="{{ workdir }}/rootfs/usr/lib/os-release"
    TMPL="src/grub.cfg.tmpl"
    DEST="{{ isoroot }}/boot/grub/grub.cfg"
    PRETTY_NAME="$(source "$OS_RELEASE" >/dev/null && echo "$PRETTY_NAME")"
    sed \
        -e "s|@PRETTY_NAME@|${PRETTY_NAME}|g" \
        -e "s|@EXTRA_KARGS@|${kargs[*]}|g" \
        "$TMPL" >"$DEST"

iso-organize extra_kargs="NONE": && (process-grub-template extra_kargs)
    #!/usr/bin/env bash
    {{ _ci_grouping }}
    set -xeuo pipefail
    mkdir -p {{ isoroot }}/boot/grub {{ isoroot }}/LiveOS
    cp {{ rootfs }}/lib/modules/*/vmlinuz {{ isoroot }}/boot
    cp {{ workdir }}/initramfs.img {{ isoroot }}/boot
    # Hardcoded on the dmsquash-live source code unless specified otherwise via kargs
    # https://github.com/dracutdevs/dracut/blob/5d2bda46f4e75e85445ee4d3bd3f68bf966287b9/modules.d/90dmsquash-live/dmsquash-live-root.sh#L24
    mv {{ workdir }}/squashfs.img {{ isoroot }}/LiveOS/squashfs.img

iso:
    #!/usr/bin/env bash
    {{ _ci_grouping }}
    {{ iso_dependencies }}
    BUILDER="$(iso_dependencies)"
    CMD='set -xeuo pipefail
    ISOROOT="$0"
    WORKDIR="$1"

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
    grub2-mkrescue -o $ISOROOT/../efiboot.img

    EFI_BOOT_MOUNT=$(mktemp -d)
    mount $ISOROOT/../efiboot.img $EFI_BOOT_MOUNT
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
    if [ "$(uname -m)" == "x86_64" ] ; then
        ARCH_SPECIFIC=("--grub2-mbr" "/usr/lib/grub/i386-pc/boot_hybrid.img")
    fi

    xorrisofs \
        -R \
        -V bluefin_boot \
        -partition_offset 16 \
        -appended_part_as_gpt \
        -append_partition 2 C12A7328-F81F-11D2-BA4B-00A0C93EC93B \
        $ISOROOT/../efiboot.img \
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
        -o /app/output.iso \
        "${ARCH_SPECIFIC[@]}" \
        $ISOROOT'
    if ! (( BUILDER )); then
        set -xeuo pipefail
        bash -c "$CMD" "$(realpath {{ isoroot }})" "$(realpath {{ workdir }})"
    else
        {{ builder_function }}
        INSTALLCMD='dnf install -y grub2 grub2-efi grub2-tools grub2-tools-extra xorriso shim dosfstools
        if [ "$(uname -m)" == "x86_64" ] ; then
            dnf install -y grub2-efi-x64-modules grub2-efi-x64-cdboot grub2-efi-x64
        elif [ "$(uname -m)" == "aarch64" ] ; then
            dnf install -y grub2-efi-aa64-modules
        fi'
        CMD="${INSTALLCMD};${CMD}"
        if [[ -f /.dockerenv || -f /run/.containerenv ]]; then
            echo '{{ style('error') }}ERROR[iso]{{ NORMAL }}: Cannot run in nested containers' >&2
            exit 1
        fi
        set -xeuo pipefail
        builder "$CMD" "/app/{{ isoroot }}" "/app/{{ workdir }}"
    fi

[no-exit-message]
@build image=default_image livesys="1" flatpaks_file="src/flatpaks.example.txt" compression="squashfs" extra_kargs="NONE" container_image=image polkit="0": \
    checkroot \
    clean \
    init-work \
    (rootfs image) \
    (ci-delete-image image) \
    initramfs \
    rootfs-setuid \
    (rootfs-include-container container_image image) \
    (rootfs-include-flatpaks canonicalize(flatpaks_file)) \
    (rootfs-include-polkit polkit) \
    (rootfs-install-livesys-scripts livesys) \
    (hook-post-rootfs HOOK_post_rootfs) \
    rootfs-clean-sysroot \
    (squash compression) \
    (iso-organize extra_kargs) \
    iso
    mv ./output.iso {{ justfile_dir() }} &>/dev/null

[no-exit-message]
@checkroot:
    if [ `id -u` -gt 0 ]; then echo '{{ style("error") }}ERROR[build]{{ NORMAL }}: Must be root to build ISO' >&2 && exit 1; fi

@clean:
    echo "{{ style('command') }}cleaning {{ absolute_path(workdir) }}...{{ NORMAL }}" >&2
    rm -rf {{ absolute_path(workdir) }}

[private]
delete-image image:
    #!/usr/bin/env bash
    set -xeuo pipefail
    {{ PODMAN }} rmi --force "{{ image }}" || :

[private]
ci-delete-image image:
    #!/usr/bin/env bash
    set -xeuo pipefail
    if [[ -n "${CI:-}" ]]; then
        {{ PODMAN }} rmi --force {{ image }} || :
    fi

vm ISO_FILE *ARGS:
    #!/usr/bin/env bash
    qemu="qemu-system-$(uname -m)"
    if [[ ! $(type -P "$qemu") ]]; then
      qemu="flatpak run --command=$qemu org.virt_manager.virt-manager"
    fi
    $qemu \
        -enable-kvm \
        -M q35 \
        -cpu host \
        -smp $(( $(nproc) / 2 > 0 ? $(nproc) / 2 : 1 )) \
        -m 4G \
        -net nic,model=virtio \
        -net user,hostfwd=tcp::2222-:22 \
        -display gtk,show-cursor=on \
        -boot d \
        -cdrom {{ ISO_FILE }} {{ ARGS }}

container-run-vm ISO_FILE:
    #!/usr/bin/env bash
    set -eoux pipefail
    # Determine an available port to use
    port=8006
    while grep -q :${port} <<< $(ss -tunalp); do
        port=$(( port + 1 ))
    done
    echo "Using Port: ${port}"
    echo "Connect to http://localhost:${port}"

    # Set up the arguments for running the VM
    run_args=()
    run_args+=(--rm --privileged)
    run_args+=(--pull=newer)
    run_args+=(--publish "127.0.0.1:${port}:8006")
    run_args+=(--env "CPU_CORES=$(( $(nproc) / 2 > 0 ? $(nproc) / 2 : 1 ))")
    mem_free=$(awk '/MemAvailable/ { printf "%.0f\n", $2/1024/1024 - 1 }' /proc/meminfo)
    ram_size=$(( mem_free > 8 ? 8 : (mem_free < 3 ? 3 : mem_free) ))
    run_args+=(--env "RAM_SIZE=${ram_size}G")
    run_args+=(--env "DISK_SIZE=64G")
    run_args+=(--env "TPM=Y")
    run_args+=(--env "GPU=Y")
    run_args+=(--device=/dev/kvm)
    run_args+=(--volume "{{ ISO_FILE }}":"/boot.iso")
    run_args+=(ghcr.io/qemus/qemu)

    # Run the VM and open the browser to connect
    {{ PODMAN }} run "${run_args[@]}" &
    xdg-open http://localhost:${port}

# Print the absolute of the files relative to the project dir.
[private]
whereis +FILE_PATHS:
    @realpath -e {{ FILE_PATHS }}
