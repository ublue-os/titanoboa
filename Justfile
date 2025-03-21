workdir := env("TITANOBOA_WORKDIR", "work")
isoroot := env("TITANOBOA_ISO_ROOT", "work/iso-root")

### UTILS TEMPLATES ###
# Stuff that comes handy to avoid repeating too much in the recipes
# (per ex.: a recurrent bash function definition).

# A bash snippet used to print the location of dnf5, or dnf as a fallback.
# To be used inside `podman run`.
tmpl_search_for_dnf := '{ which dnf5 || which dnf; } 2>/dev/null'
#######################

init-work:
    mkdir -p {{ workdir }}
    mkdir -p {{ isoroot }}

initramfs $IMAGE: init-work
    #!/usr/bin/env bash
    # THIS NEEDS dracut-live
    set -xeuo pipefail
    # sudo podman pull $IMAGE
    sudo podman run --privileged --rm -i -v .:/app:Z $IMAGE \
        sh <<'INITRAMFSEOF'
    set -xeuo pipefail
    sudo dnf install -y dracut dracut-live kernel
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
    PATH=/var/tmp/bin:$PATH dracut --zstd --reproducible --no-hostonly --add "dmsquash-live dmsquash-live-autooverlay" --force /app/{{ workdir }}/initramfs.img
    INITRAMFSEOF

rootfs $IMAGE: init-work
    #!/usr/bin/env bash
    set -xeuo pipefail
    ROOTFS="{{ workdir }}/rootfs"
    mkdir -p $ROOTFS
    ctr="$(sudo podman create --rm "${IMAGE}")" && trap "sudo podman rm $ctr" EXIT
    sudo podman export $ctr | tar -xf - -C "${ROOTFS}"

    # Make /var/tmp be a tmpfs by symlinking to /tmp,
    # in order to make bootc work at runtime.
    rm -r "$ROOTFS"/var/tmp
    ln -sr "$ROOTFS"/tmp "$ROOTFS"/var/tmp

rootfs-setuid:
    #!/usr/bin/env bash
    set -xeuo pipefail
    ROOTFS="{{ workdir }}/rootfs"
    sudo sh -c "
    for file in usr/bin/sudo usr/lib/polkit-1/polkit-agent-helper-1 usr/bin/passwd /usr/bin/pkexec ; do
        chmod u+s ${ROOTFS}/\${file}
    done"

rootfs-include-container $IMAGE:
    #!/usr/bin/env bash
    set -xeuo pipefail
    ROOTFS="{{ workdir }}/rootfs"
    # Needs to exist so that we can mount to it
    sudo mkdir -p "${ROOTFS}/var/lib/containers/storage"
    # Remove signatures as signed images get super mad when you do this
    sudo podman push "${IMAGE}" "containers-storage:[overlay@$(realpath "$ROOTFS")/var/lib/containers/storage]$IMAGE" --remove-signatures
    # We need this in the rootfs specifically so that bootc can know what images are on disk via podman
    sudo curl -fSsLo "${ROOTFS}/usr/bin/fuse-overlayfs" "https://github.com/containers/fuse-overlayfs/releases/download/v1.14/fuse-overlayfs-$(arch)"
    sudo chmod +x "${ROOTFS}/usr/bin/fuse-overlayfs"

rootfs-include-flatpaks $FLATPAKS_FILE="src/flatpaks.example.txt":
    #!/usr/bin/env bash
    set -xeuo pipefail
    if [ ! -f "$FLATPAKS_FILE" ] ; then
        echo "Flatpak file seems to not exist, are you sure you gave me the right path? Here it is: $FLATPAKS_FILE"
        exit 1
    fi
    ROOTFS="{{ workdir }}/rootfs"

    set -xeuo pipefail
    sudo podman run --privileged --rm -i -v ".:/app:Z" -v "./${ROOTFS}:/rootfs:Z" registry.fedoraproject.org/fedora:41 \
    <<"LIVESYSEOF"
    set -xeuo pipefail
    sudo dnf install -y flatpak
    sudo mkdir -p /etc/flatpak/installations.d /rootfs/var/lib/flatpak
    sudo tee /etc/flatpak/installations.d/liveiso.conf <<EOF
    [Installation "liveiso"]
    Path=/rootfs/var/lib/flatpak/
    EOF
    flatpak remote-add --installation=liveiso --if-not-exists flathub "https://dl.flathub.org/repo/flathub.flatpakrepo"
    cat /app/{{ FLATPAKS_FILE }} | xargs flatpak install -y --installation=liveiso
    LIVESYSEOF

rootfs-install-livesys-scripts: init-work
    #!/usr/bin/env bash
    set -xeuo pipefail
    ROOTFS="{{ workdir }}/rootfs"
    sudo podman run --security-opt label=type:unconfined_t -i --rootfs "$(realpath ${ROOTFS})" /usr/bin/bash \
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

squash $IMAGE: init-work
    #!/usr/bin/env bash
    set -xeuo pipefail
    ROOTFS="{{ workdir }}/rootfs"
    # Needs to be squashfs.img due to dracut default name (can be configured on grub.cfg)
    if [ -e "{{ workdir }}/squashfs.img" ] ; then
        exit 0
    fi
    sudo podman run --privileged --rm -i -v ".:/app:Z" -v "./${ROOTFS}:/rootfs:Z" registry.fedoraproject.org/fedora:41 \
        sh <<"SQUASHEOF"
    set -xeuo pipefail
    sudo dnf install -y erofs-utils
    mkfs.erofs --all-root -zlz4hc,9 -Eall-fragments,fragdedupe=inode -C1048576 /app/{{ workdir }}/squashfs.img /rootfs
    SQUASHEOF

iso-organize: init-work
    #!/usr/bin/env bash
    set -xeuo pipefail
    mkdir -p {{ isoroot }}/boot/grub {{ isoroot }}/LiveOS
    cp src/grub.cfg {{ isoroot }}/boot/grub
    cp {{ workdir }}/rootfs/lib/modules/*/vmlinuz {{ isoroot }}/boot
    sudo cp {{ workdir }}/initramfs.img {{ isoroot }}/boot
    sudo mv {{ workdir }}/squashfs.img {{ isoroot }}/LiveOS/squashfs.img

iso:
    #!/usr/bin/env bash
    set -xeuo pipefail
    sudo podman run --privileged --rm -i -v ".:/app:Z" registry.fedoraproject.org/fedora:41 \
        sh <<"ISOEOF"
    set -xeuo pipefail
    sudo dnf install -y grub2 grub2-efi grub2-efi-x64-modules grub2-efi-x64-cdboot grub2-efi-x64 grub2-tools-extra xorriso
    grub2-mkrescue --xorriso=/app/src/xorriso_wrapper.sh -o /app/output.iso /app/{{ isoroot }}
    ISOEOF

build image livesys="0" clean_rootfs="1" flatpaks_file="src/flatpaks.example.txt":
    #!/usr/bin/env bash
    set -xeuo pipefail
    just clean "{{ clean_rootfs }}"
    just initramfs "{{ image }}"
    just rootfs "{{ image }}"
    just rootfs-setuid
    just rootfs-include-container "{{ image }}"
    just rootfs-include-flatpaks "{{ flatpaks_file }}"

    if [[ {{ livesys }} == 1 ]]; then
      just rootfs-install-livesys-scripts
    fi

    just squash "{{ image }}"
    just iso-organize
    just iso

clean clean_rootfs="1":
    #!/usr/bin/env bash
    sudo umount work/rootfs/var/lib/containers/storage/overlay/ || true
    sudo umount work/rootfs/containers/storage/overlay/ || true
    sudo umount work/iso-root/containers/storage/overlay/ || true
    sudo rm -rf output.iso
    [ "{{ clean_rootfs }}" == "1" ] && sudo rm -rf {{ workdir }}

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
