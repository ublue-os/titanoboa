#!/usr/bin/env -S bash -exo pipefail

{ export PS4='+( ${BASH_SOURCE}:${LINENO} ): ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'; } 2>/dev/null

dnf install -y squashfs-tools xorriso yq mtools dosfstools

mkdir -p \
    /work \
    /work/iso-root \
    /work/iso-root/boot/grub2 \
    /work/iso-root/images/pxeboot \
    /work/iso-root/LiveOS
cd /work || exit 1

# Create the squashfs image of the container image
mksquashfs /rootfs /work/iso-root/LiveOS/squashfs.img -all-root -noappend -e sysroot -e ostree -comp zstd -Xcompression-level 19

iso_config_file=/rootfs/usr/lib/bootc-image-builder/iso.yaml
if [[ ! -f $iso_config_file ]]; then
    echo >&2 "ERROR: Missing /usr/lib/bootc-image-builder/iso.yaml file"
    exit 1
fi

iso_label=$(yq '.label' <$iso_config_file)

# Copy initrd and kernel
cp -av /rootfs/usr/lib/modules/*/initramfs.img /work/iso-root/images/pxeboot/initrd.img
cp -av /rootfs/usr/lib/modules/*/vmlinuz /work/iso-root/images/pxeboot/vmlinuz

# Copy GRUB modules
for grub_arch in i386-pc arm64-efi; do
    [ -f "/rootfs/usr/lib/grub/$grub_arch" ] || continue
    echo >&2 "Found $grub_arch files, copying to /work/iso-root/boot/grub2/$grub_arch ..."
    cp -avT /rootfs/usr/lib/grub/$grub_arch /work/iso-root/boot/grub2/$grub_arch
done

# Copy efi dir
cp -avT /rootfs/boot/efi/EFI /work/EFI

# Generate grub.cfg
{ grub_cfg="$(</dev/stdin)"; } <<EOF
set timeout=$(yq '.grub2.timeout // 10' <$iso_config_file)
set default="$(yq '.grub2.default // 0' <$iso_config_file)"
set menu_auto_hide=false

function load_video {
  insmod all_video
}

load_video
set gfxpayload=keep
insmod gzio
insmod part_gpt
insmod chain

search --no-floppy --set=root -l '$iso_label'

EOF
for i in $(yq '.grub2.entries | keys | .[]' <"$iso_config_file"); do
    entry_name=$(yq ".grub2.entries[$i].name" <"$iso_config_file")
    entry_linux=$(yq ".grub2.entries[$i].linux" <"$iso_config_file")
    entry_initrd=$(yq ".grub2.entries[$i].initrd" <"$iso_config_file")
    { grub_cfg+=$'\n'"$(</dev/stdin)"; } <<EOF
menuentry '$entry_name' {
  linux $entry_linux
  initrd $entry_initrd
}
EOF
done

for dir in /work/EFI/* /work/iso-root/boot/grub2; do
    echo "$grub_cfg" >"$dir/grub.cfg"
done

# For some reason, fedora also copies EFI into /boot/EFI (?), probably because of hardcoded prefix in grub/shim
cp -avT /work/EFI /work/iso-root/EFI

# Generate uefi.img
pushd /work || exit 1
truncate -s 100M /work/uefi.img
mkfs.fat -F32 /work/uefi.img
mcopy -v -i /work/uefi.img -s /work/EFI ::
xorriso -as mkisofs \
    -R \
    -V "$iso_label" \
    -partition_offset 16 \
    -appended_part_as_gpt \
    -append_partition 2 C12A7328-F81F-11D2-BA4B-00A0C93EC93B ./uefi.img \
    -iso_mbr_part_type EBD0A0A2-B9E5-4433-87C0-68B6B72699C7 \
    -e --interval:appended_partition_2:all:: \
    -no-emul-boot \
    -iso-level 3 \
    -o "/output/$iso_label.iso" \
    iso-root
