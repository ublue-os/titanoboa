# Titanoboa

A [bootc](https://github.com/bootc-dev/bootc) installer designed to install an image as quickly as possible. This project enables the creation of bootable ISOs directly from bootc container images, where all customizations are embedded within the container image itself.

## Mission

This is an experiment to see how far we can get building our own ISOs. The objective is to:

- Generate a LiveCD so users can try out an image before committing
- Install the image and flatpaks to a selected disk with minimal user-input
- Basically be an MVP for `bootc install`

## Why?

Waiting for existing installers to move to cloud native is untenable, let's see if we can remove that external dependency forever. 😈

---

## End-User Documentation

This guide explains how to consume Titanoboa to create a live ISO image of your custom bootc container image.

### Table of Contents

- [Prerequisites](#prerequisites)
- [Container Image Specification](#container-image-specification)
- [GitHub Actions Integration](#github-actions-integration)
- [Local ISO Generation](#local-iso-generation)
- [Testing Your ISO](#testing-your-iso)

### Prerequisites

Before using Titanoboa, ensure you have:

1.  **A bootc-compatible container image** hosted in a container registry (e.g., GitHub Container Registry, Docker Hub, Quay.io) or locally stored in podman's container storage. This image _must_ adhere to the [Container Image Specification](#container-image-specification).
2.  **GitHub Actions** (for automated builds).

### Container Image Specification

Your `bootc` container image must adhere to a specific contract for Titanoboa to successfully build an ISO. All customizations for the ISO (bootloader entries, kernel arguments, Flatpaks, etc.) are expected to be embedded within your container image.

This contract is also known as the [Container-native ISO contract v0.1.0 spec](https://github.com/ondrejbudai/bootc-isos/blob/3b3a185e4a57947f57baf53d2be5aee469274f98/README.md#container-native-iso-contract-v010).

#### `iso.yaml`

Your container image must contain a file at `/usr/lib/bootc-image-builder/iso.yaml` in YAML format. This file configures the ISO's label and GRUB2 boot entries.

The `iso.yaml` file supports the following top-level keys:

- `label` (string): The label for the ISO.
- `grub2` (object): GRUB2 configuration, supporting these keys:
  - `default` (integer): The default menu item (0-indexed).
  - `timeout` (integer): Default timeout in seconds.
  - `entries` (array of objects): GRUB2 menu entries. Each entry must have:
    - `name` (string): Name of the entry.
    - `linux` (string): Path to the kernel + kernel arguments (e.g., `/images/pxeboot/vmlinuz quiet rhgb`).
    - `initrd` (string): Path to the initramfs (e.g., `/images/pxeboot/initrd.img`).

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

#### Required Files

In addition to `iso.yaml`, your container image is expected to contain:

- **Kernel**: In `/usr/lib/modules/*/vmlinuz`
- **Initramfs**: Next to the kernel, named `initramfs.img`
- **UEFI EFI binaries**: In `/boot/efi/EFI/$VENDOR` (e.g., `shimx64.efi`, `mmx64.efi`, `gcdx64.efi`)
- **GRUB2 modules**: In `/usr/lib/grub/i386-pc`

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

### Local ISO Generation

For local development and testing, you can build ISOs directly from a local container image that adheres to the [Container Image Specification](#container-image-specification).

First, build your container image:

```bash
sudo podman build --cap-add sys_admin --security-opt label=disable --squash -t your-local-image-name .
```

Then, run the `main.sh` script, providing your locally built image:

```bash
sudo TITANOBOA_CTR_IMAGE="your-local-image-name" ./main.sh
```

You can also use the titanoboa container directly to build your ISOs:

```bash
sudo podman run --rm -it \
    --security-opt label=disable \
    -v ./output:/output \
    -v /var/lib/containers/storage:/usr/lib/containers/storage:ro \
    --mount type=image,source="your-local-image-name",dst=/rootfs \
    ghcr.io/ublue-os/titanoboa:latest
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
