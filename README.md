# Titanoboa (Beta)

A [bootc](https://github.com/bootc-dev/bootc) installer designed to install an image as quickly as possible. This project enables the creation of bootable ISOs directly from bootc container images, where all customizations are embedded within the container image itself.

## Mission

This is an experiment to see how far we can get building our own ISOs. The objective is to:

- Generate a LiveCD so users can try out an image before committing
- Install the image and flatpaks to a selected disk with minimal user-input
- Basically be an MVP for `bootc install` 

## Why?

Waiting for existing installers to move to cloud native is untenable, let's see if we can remove that external dependency forever. 😈

## Components

- LiveCD

---

## End-User Documentation

This guide explains how to consume Titanoboa to create a live ISO image of your custom bootc container image. The key principle is that your `bootc` container image is the **single source of truth** for all ISO configurations.

### Table of Contents

- [Prerequisites](#prerequisites)
- [GitHub Actions Integration](#github-actions-integration)
- [Container Image Contract (`iso.yaml`)](#container-image-contract-iso.yaml)
- [Local ISO Generation](#local-iso-generation)
- [Testing Your ISO](#testing-your-iso)

### Prerequisites

Before using Titanoboa, ensure you have:

1.  **A bootc-compatible container image** hosted in a container registry (e.g., GitHub Container Registry, Docker Hub, Quay.io). This image *must* contain all necessary kernel, initramfs, EFI files, and a `/usr/lib/bootc-image-builder/iso.yaml` configuration file for GRUB2 and ISO labeling. Check the [spec](https://github.com/ondrejbudai/bootc-isos/blob/3b3a185e4a57947f57baf53d2be5aee469274f98/README.md#container-native-iso-contract-v010).
2.  **GitHub Actions** (for automated builds).

### GitHub Actions Integration

Titanoboa is designed to be consumed as a GitHub Action. Here's how to integrate it into your workflow:

#### Basic Usage

Add Titanoboa as a step in your GitHub Actions workflow:

```yaml
- name: Build ISO
  uses: ublue-os/titanoboa@main
  with:
    image-ref: ghcr.io/your-org/your-image:latest
```

#### Real-World Example (from `ublue-os/bluefin`)

This example shows how an image like `ublue-os/bluefin` consumes Titanoboa, assuming the `bluefin-dx:gts` image already contains its full ISO configuration.

```yaml
- name: Build ISO
  id: build
  uses: ublue-os/titanoboa@main
  with:
    image-ref: ghcr.io/ublue-os/bluefin-dx:gts

- name: Rename and Checksum ISO
  run: |
    mkdir -p output
    mv ${{ steps.build.outputs.iso-dest }} output/my-custom-image.iso
    (cd output && sha256sum my-custom-image.iso | tee my-custom-image.iso-CHECKSUM)

- name: Upload ISO
  uses: actions/upload-artifact@v4
  with:
    name: custom-iso
    path: output/
```

### Container Image Contract (`iso.yaml`)

Your `bootc` container image must adhere to a specific contract for Titanoboa to successfully build an ISO. All customizations for the ISO (bootloader entries, kernel arguments, Flatpaks, etc.) are expected to be embedded within your container image.

Specifically, your container image must contain a file at `/usr/lib/bootc-image-builder/iso.yaml` in YAML format. This file configures the ISO's label and GRUB2 boot entries.

The `iso.yaml` file supports the following top-level keys:

-   `label` (string): The label for the ISO.
-   `grub2` (object): GRUB2 configuration, supporting these keys:
    -   `default` (integer): The default menu item (0-indexed).
    -   `timeout` (integer): Default timeout in seconds.
    -   `entries` (array of objects): GRUB2 menu entries. Each entry must have:
        -   `name` (string): Name of the entry.
        -   `linux` (string): Path to the kernel + kernel arguments (e.g., `/images/pxeboot/vmlinuz quiet rhgb`).
        -   `initrd` (string): Path to the initramfs (e.g., `/images/pxeboot/initrd.img`).

**Example `iso.yaml` (inside your container image):**

```yaml
label: MyCustomImage-ISO
grub2:
  default: 0
  timeout: 10
  entries:
    - name: "My Custom Image Live"
      linux: "/images/pxeboot/vmlinuz quiet rhgb root=live:CDLABEL=MyCustomImage-ISO enforcing=0 rd.live.image"
      initrd: "/images/pxeboot/initrd.img"
    - name: "My Custom Image Live (Basic Graphics)"
      linux: "/images/pxeboot/vmlinuz quiet rhgb root=live:CDLABEL=MyCustomImage-ISO enforcing=0 rd.live.image nomodeset"
      initrd: "/images/pxeboot/initrd.img"
```

In addition to `iso.yaml`, your container image is expected to contain:

-   Kernel: In `/usr/lib/modules/*/vmlinuz`
-   Initramfs: Next to the kernel, named `initramfs.img`
-   UEFI EFI binaries: In `/boot/efi/EFI/$VENDOR` (e.g., `shimx64.efi`, `mmx64.efi`, `gcdx64.efi`)
-   GRUB2 modules: In `/usr/lib/grub/i386-pc`

### Local ISO Generation

For local development and testing, you can build ISOs directly from a local container image that adheres to the [Container-native ISO contract v0.1.0 spec](https://github.com/ondrejbudai/bootc-isos/blob/3b3a185e4a57947f57baf53d2be5aee469274f98/README.md#container-native-iso-contract-v010).

First, build your container image:

```bash
sudo podman build --cap-add sys_admin --security-opt label=disable -t your-local-image-name .
```

Then, run the `main.sh` script, providing your locally built image:

```bash
sudo TITANOBOA_CTR_IMAGE="your-local-image-name" ./main.sh
```

The generated ISO will be placed in the `output/` directory by default.

### Testing Your ISO

After building your ISO via the GitHub Action, you can download the artifact and test it in a virtual machine locally. For local testing during development, you can adapt the `main.sh` script to build the ISO from a local bootc image.

Example of how to run the VM locally (if you have QEMU installed):

```bash
# Example: Assuming you downloaded your ISO to ./output/my-custom-image.iso
qemu-system-x86_64 \
    -enable-kvm \
    -M q35 \
    -cpu host \
    -smp 2 \
    -m 4G \
    -net nic,model=virtio \
    -net user,hostfwd=tcp::2222-:22 \
    -display gtk,show-cursor=on \
    -boot d \
    -cdrom ./output/my-custom-image.iso
```