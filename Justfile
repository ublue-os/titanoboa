export PODMAN := if path_exists("/usr/bin/podman") == "true" { env("PODMAN", "/usr/bin/podman") } else if path_exists("/usr/bin/docker") == "true" { env("PODMAN", "docker") } else { env("PODMAN", "exit 1 ; ") }
workdir := env("TITANOBOA_WORKDIR", "work")
isoroot := env("TITANOBOA_ISO_ROOT", "work/iso-root")

### UTILS TEMPLATES ###
# Stuff that comes handy to avoid repeating too much in the recipes
# (per ex.: a recurrent bash function definition).

# A bash snippet used to print the location of dnf5, or dnf as a fallback.
# To be used inside `"podman run`.
tmpl_search_for_dnf := '{ which dnf5 || which dnf; } 2>/dev/null'
#######################

init-work:
    mkdir -p {{ workdir }}
    mkdir -p {{ isoroot }}

initramfs $IMAGE: init-work
    #!/usr/bin/env bash
    set -xeuo pipefail
    # sudo "${PODMAN}" pull $IMAGE
    sudo "${PODMAN}" run --privileged --rm -i -v .:/app:Z $IMAGE \
        sh <<'INITRAMFSEOF'
    set -xeuo pipefail
    dnf install -y dracut dracut-live kernel
    INSTALLED_KERNEL=$(rpm -q kernel-core --queryformat "%{evr}.%{arch}" | tail -n 1)
    cat >/app/work/fake-uname <<EOF
    #!/usr/bin/env bash

    if [ "\$1" == "-r" ] ; then
      echo ${INSTALLED_KERNEL}
      exit 0
    fi

    exec /usr/bin/uname \$@
    EOF
    install -Dm0755 /app/work/fake-uname /var/tmp/bin/uname
    mkdir -p $(realpath /root)
    cp /app/src/fstab.sys /etc/fstab.sys
    PATH=/var/tmp/bin:$PATH dracut --zstd --reproducible --no-hostonly --add "fstab-sys dmsquash-live dmsquash-live-autooverlay" --force /app/{{ workdir }}/initramfs.img
    INITRAMFSEOF

rootfs $IMAGE: init-work
    #!/usr/bin/env bash
    set -xeuo pipefail
    ROOTFS="{{ workdir }}/rootfs"
    mkdir -p $ROOTFS
    ctr="$(sudo "${PODMAN}" create --rm "${IMAGE}" /usr/bin/bash)" && trap "sudo "${PODMAN}" rm $ctr" EXIT
    sudo "${PODMAN}" export $ctr | tar -xf - -C "${ROOTFS}"

    # Make /var/tmp be a tmpfs by symlinking to /tmp,
    # in order to make bootc work at runtime.
    rm -rf "$ROOTFS"/var/tmp
    ln -sr "$ROOTFS"/tmp "$ROOTFS"/var/tmp

rootfs-setuid:
    #!/usr/bin/env bash
    set -xeuo pipefail
    ROOTFS="{{ workdir }}/rootfs"
    sudo sh -c "
    for file in usr/bin/sudo usr/lib/polkit-1/polkit-agent-helper-1 usr/bin/passwd /usr/bin/pkexec usr/bin/fusermount3 ; do
        chmod u+s ${ROOTFS}/\${file}
    done"

squash-container $IMAGE:
    #!/usr/bin/env bash
    set -xeuo pipefail
    ROOTFS="{{ workdir }}/rootfs"
    ISO_ROOTFS="{{ isoroot }}"
    # Needs to exist so that we can mount to it
    sudo mkdir -p "${ROOTFS}/usr/lib/containers/storage"
    # Remove signatures as signed images get super mad when you do this
    sudo "${PODMAN}" push "${IMAGE}" "containers-storage:[overlay@$(realpath "{{ workdir }}")/containers-storage]$IMAGE" --remove-signatures
    # We need this in the rootfs specifically so that bootc can know what images are on disk via "${PODMAN}"
    sudo curl -fSsLo "${ROOTFS}/usr/bin/fuse-overlayfs" "https://github.com/containers/fuse-overlayfs/releases/download/v1.14/fuse-overlayfs-$(arch)"
    sudo chmod +x "${ROOTFS}/usr/bin/fuse-overlayfs"
    sudo "${PODMAN}" run --privileged --rm -i -v ".:/app:Z" registry.fedoraproject.org/fedora:41 \
    sh <<"CONTAINEREOF"
    dnf install -y erofs-utils
    mkfs.erofs --quiet --all-root -zlz4hc,6 -Eall-fragments,fragdedupe=inode -C1048576 /app/{{ workdir }}/container.img /app/{{ workdir }}/containers-storage
    CONTAINEREOF
    sudo umount "{{ workdir }}/containers-storage/overlay"
    sudo rm -rf "{{ workdir }}/containers-storage"

squash-flatpaks $FLATPAKS_FILE="src/flatpaks.example.txt":
    #!/usr/bin/env bash
    set -x
    if [ ! -f "$FLATPAKS_FILE" ] ; then
        echo "Flatpak file seems to not exist, are you sure you gave me the right path? Here it is: $FLATPAKS_FILE"
        exit 1
    fi
    ROOTFS="{{ workdir }}/rootfs"
    sudo mkdir -p "${ROOTFS}/var/lib/flatpak"

    set -xeuo pipefail
    sudo "${PODMAN}" run --privileged --rm -i -v ".:/app:Z" registry.fedoraproject.org/fedora:41 \
    <<"LIVESYSEOF"
    set -xeuo pipefail
    dnf install -y flatpak erofs-utils
    mkdir -p /etc/flatpak/installations.d /app/{{ workdir }}/flatpak
    TARGET_INSTALLATION_NAME="liveiso"
    tee /etc/flatpak/installations.d/liveiso.conf <<EOF
    [Installation "${TARGET_INSTALLATION_NAME}"]
    Path=/app/{{ workdir }}/flatpak
    EOF
    flatpak remote-add --installation="${TARGET_INSTALLATION_NAME}" --if-not-exists flathub "https://dl.flathub.org/repo/flathub.flatpakrepo"
    grep -v "#.*" /app/{{ FLATPAKS_FILE }} | sort --reverse | xargs '-i{}' -d '\n' sh -c "flatpak remote-info --installation=${TARGET_INSTALLATION_NAME} --system flathub app/{}/$(arch)/stable &>/dev/null && flatpak install --noninteractive -y --installation=${TARGET_INSTALLATION_NAME} {}"
    mkfs.erofs --quiet --all-root -zlz4hc,6 -Eall-fragments,fragdedupe=inode -C1048576 /app/{{ workdir }}/flatpak.img /app/{{ workdir }}/flatpak
    rm -f /etc/flatpak/installations.d/liveiso.conf
    rm -rf /app/{{ workdir }}/flatpak
    LIVESYSEOF

rootfs-install-livesys-scripts: init-work
    #!/usr/bin/env bash
    set -xeuo pipefail
    ROOTFS="{{ workdir }}/rootfs"
    sudo "${PODMAN}" run --security-opt label=type:unconfined_t -i --rootfs "$(realpath ${ROOTFS})" /usr/bin/bash \
    <<"LIVESYSEOF"
    set -xeuo pipefail
    dnf="$({{tmpl_search_for_dnf}})"
    $dnf install -y livesys-scripts

    # Determine desktop environment. Must match one of /usr/libexec/livesys/sessions.d/livesys-{desktop_env}
    desktop_env=""
    # We can tell what desktop environment we are targeting by looking at
    # the session files. Lets decide by the first file found.
    _session_file="$(find /usr/share/wayland-sessions/ /usr/share/xsessions \
        -maxdepth 1 -type f -name '*.desktop' -printf '%P' -quit)"
    case $_session_file in
    # TODO (@Zeglius Thu Mar 20 2025): add more sessions.
    plasma.desktop) desktop_env=kde   ;;
    gnome*)         desktop_env=gnome ;;
    xfce.desktop)   desktop_env=xfce  ;;
    *)
        echo "ERROR[rootfs-install-livesys-scripts]: no matching desktop enviroment found"\
            " at /usr/share/wayland-sessions/ /usr/share/xsessions";
        exit 1
    ;;
    esac && unset -v _session_file
    sed -i "s/^livesys_session=.*/livesys_session=${desktop_env}/" /etc/sysconfig/livesys

    # Enable services
    systemctl enable livesys.service livesys-late.service
    LIVESYSEOF

# Hook used for custom operations done in the rootfs before it is squashed.
# Only accept inputs by stdin. Meant to be used in a GH action.
[private]
hook-post-rootfs: init-work
    #!/usr/bin/env bash
    set -xeuo pipefail
    ROOTFS="{{ workdir }}/rootfs"
    sudo "${PODMAN}" run --rm --security-opt label=type:unconfined_t -i -v ".:/app:Z" --rootfs "$(realpath ${ROOTFS})" /usr/bin/bash \
        </dev/stdin

squash: init-work
    #!/usr/bin/env bash
    set -xeuo pipefail
    ROOTFS="{{ workdir }}/rootfs"
    # Needs to be squashfs.img due to dracut default name (can be configured on grub.cfg)
    if [ -e "{{ workdir }}/squashfs.img" ] ; then
        exit 0
    fi
    sudo "${PODMAN}" run --privileged --rm -i -v ".:/app:Z" -v "./${ROOTFS}:/rootfs:Z" registry.fedoraproject.org/fedora:41 \
        sh <<"SQUASHEOF"
    set -xeuo pipefail
    dnf install -y erofs-utils
    mkfs.erofs --quiet --all-root -zlz4hc,6 -Eall-fragments,fragdedupe=inode -C1048576 /app/{{ workdir }}/squashfs.img /rootfs
    SQUASHEOF

iso-organize: init-work
    #!/usr/bin/env bash
    set -xeuo pipefail
    # Everything here is arbitrary, feel free to modify the paths.
    # just make sure to edit the grub config & fstab first.
    mkdir -p {{ isoroot }}/boot/grub {{ isoroot }}/LiveOS
    cp {{ workdir }}/rootfs/lib/modules/*/vmlinuz {{ isoroot }}/boot
    sudo cp {{ workdir }}/initramfs.img {{ isoroot }}/boot
    sudo mv {{ workdir }}/flatpak.img {{ isoroot }}/LiveOS/flatpak.img
    sudo mv {{ workdir }}/container.img {{ isoroot }}/LiveOS/container.img
    # Needs to be under `/boot/grub` or `grub2`, this depends on what is the grub name during grub compilation
    cp src/grub.cfg {{ isoroot }}/boot/grub
    # Hardcoded on the dmsquash-live source code unless specified otherwise via kargs
    # https://github.com/dracutdevs/dracut/blob/5d2bda46f4e75e85445ee4d3bd3f68bf966287b9/modules.d/90dmsquash-live/dmsquash-live-root.sh#L24
    sudo mv {{ workdir }}/squashfs.img {{ isoroot }}/LiveOS/squashfs.img

iso:
    #!/usr/bin/env bash
    set -xeuo pipefail
    sudo "${PODMAN}" run --privileged --rm -i -v ".:/app:Z" registry.fedoraproject.org/fedora:41 \
        sh <<"ISOEOF"
    set -x
    ISOROOT="$(realpath /app/{{ isoroot }})"
    WORKDIR="$(realpath /app/{{ workdir }})"
    dnf install -y grub2 grub2-efi grub2-tools grub2-tools-extra xorriso shim dosfstools
    if [ "$(arch)" == "x86_64" ] ; then
        dnf install -y grub2-efi-x64-modules grub2-efi-x64-cdboot grub2-efi-x64
    elif [ "$(arch)" == "aarch64" ] ; then
        dnf install -y grub2-efi-aa64-modules
    fi

    mkdir -p $ISOROOT/EFI/BOOT
    # ARCH_SHORT needs to be uppercase
    ARCH_SHORT="$(arch | sed 's/x86_64/X64/g' | sed 's/aarch64/AA64/g')"
    ARCH_32="$(arch | sed 's/x86_64/ia32/g' | sed 's/aarch64/arm/g')"
    cp -avf /boot/efi/EFI/fedora/. $ISOROOT/EFI/BOOT
    cp -avf $ISOROOT/boot/grub/grub.cfg $ISOROOT/EFI/BOOT/BOOT.conf
    cp -avf $ISOROOT/boot/grub/grub.cfg $ISOROOT/EFI/BOOT/grub.cfg
    cp -avf /boot/grub*/fonts/unicode.pf2 $ISOROOT/EFI/BOOT/fonts
    cp -avf $ISOROOT/EFI/BOOT/shimx64.efi "$ISOROOT/EFI/BOOT/BOOT${ARCH_SHORT}.efi"
    cp -avf $ISOROOT/EFI/BOOT/shim.efi "$ISOROOT/EFI/BOOT/BOOT${ARCH_32}.efi"

    ARCH_GRUB="$(arch | sed 's/x86_64/i386-pc/g' | sed 's/aarch64/arm64-efi/g')"
    ARCH_OUT="$(arch | sed 's/x86_64/i386-pc-eltorito/g' | sed 's/aarch64/arm64-efi/g')"
    ARCH_MODULES="$(arch | sed 's/x86_64/biosdisk/g' | sed 's/aarch64/efi_gop/g')"

    grub2-mkimage -O $ARCH_OUT -d /usr/lib/grub/$ARCH_GRUB -o $ISOROOT/boot/eltorito.img -p /boot/grub iso9660 $ARCH_MODULES
    grub2-mkrescue -o $ISOROOT/../efiboot.img

    EFI_BOOT_MOUNT=$(mktemp -d)
    mount $ISOROOT/../efiboot.img $EFI_BOOT_MOUNT
    cp -r $EFI_BOOT_MOUNT/boot/grub $ISOROOT/boot/
    umount $EFI_BOOT_MOUNT
    rm -rf $EFI_BOOT_MOUNT

    # https://github.com/FyraLabs/katsu/blob/1e26ecf74164c90bc24299a66f8495eb2aef4845/src/builder.rs#L145
    EFI_BOOT_PART=$(mktemp -d)
    fallocate $WORKDIR/efiboot.img -l 15M
    mkfs.msdos -v -n EFI $WORKDIR/efiboot.img
    mount $WORKDIR/efiboot.img $EFI_BOOT_PART
    mkdir -p $EFI_BOOT_PART/EFI/BOOT
    cp -avr $ISOROOT/EFI/BOOT/. $EFI_BOOT_PART/EFI/BOOT
    umount $EFI_BOOT_PART

    ARCH_SPECIFIC=()
    if [ "$(arch)" == "x86_64" ] ; then
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
        $ISOROOT
    ISOEOF

build image livesys="0" clean="1" flatpaks_file="src/flatpaks.example.txt":
    #!/usr/bin/env bash
    set -xeuo pipefail

    # We pass hooks contents with file descriptors:
    # - 3: hook_post_rootfs
    unset -v hook_post_rootfs 2>/dev/null || :
    { readarray -d'' -t hook_post_rootfs <&3; } 2>/dev/null || :

    if [ "{{ clean }}" == "1" ] ; then
        just clean
    fi 
    just initramfs "{{ image }}"
    just rootfs "{{ image }}"
    just rootfs-setuid
    just squash-container "{{ image }}"
    just squash-flatpaks "{{ flatpaks_file }}"

    if [[ {{ livesys }} == 1 ]]; then
      just rootfs-install-livesys-scripts
    fi

    # Run hooks
    if [[ -v hook-post-rootfs ]]; then
      just hook-post-rootfs <<<"hook_post_rootfs"
    fi

    just squash
    just iso-organize
    just iso

clean:
    #!/usr/bin/env bash
    sudo umount work/rootfs/var/lib/containers/storage/overlay/ || true
    sudo umount work/rootfs/containers/storage/overlay/ || true
    sudo umount work/iso-root/containers/storage/overlay/ || true
    sudo rm -rf {{ workdir }}

vm ISO_FILE *ARGS:
    #!/usr/bin/env bash
    qemu="qemu-system-$(arch)"
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
    run_args+=(docker.io/qemux/qemu-docker)

    # Run the VM and open the browser to connect
    "${PODMAN}" run "${run_args[@]}" &
    xdg-open http://localhost:${port}

# Print the absolute of the files relative to the project dir.
[private]
whereis +FILE_PATHS:
    @realpath -e {{ FILE_PATHS }}
