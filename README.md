# Titanoboa (Beta)

A [bootc](https://github.com/bootc-dev/bootc) installer designed to install an image as quickly as possible. Handles a live user session and then hands off to Anaconda or Readymade for installation. 

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

This guide explains how to consume Titanoboa to create a live ISO image of your custom bootc container image. The [@ublue-os/bluefin](https://github.com/ublue-os/bluefin) repository is the canonical example of this integration.

### Table of Contents

- [Prerequisites](#prerequisites)
- [GitHub Actions Integration](#github-actions-integration)
- [Action Inputs Reference](#action-inputs-reference)
- [Configuration Files](#configuration-files)
- [Local Usage with Just](#local-usage-with-just)
- [Environment Variables](#environment-variables)
- [Complete Example Workflow](#complete-example-workflow)
- [Testing Your ISO](#testing-your-iso)

### Prerequisites

Before using Titanoboa, ensure you have:

1. **A bootc-compatible container image** hosted in a container registry (e.g., GitHub Container Registry, Docker Hub, Quay.io)
2. **GitHub Actions** (for automated builds) or **Just** + **Podman** (for local builds)
3. **Root/sudo access** when building locally
4. **Sufficient disk space** (at least 20-30 GB free for building ISOs)

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

#### Real-World Example from Bluefin

This example shows how [@ublue-os/bluefin](https://github.com/ublue-os/bluefin) consumes Titanoboa:

```yaml
- name: Build ISO
  id: build
  uses: ublue-os/titanoboa@main
  with:
    image-ref: ghcr.io/ublue-os/bluefin-dx:gts
    flatpaks-list: ${{ github.workspace }}/flatpaks/system-flatpaks.list
    hook-post-rootfs: ${{ github.workspace }}/iso_files/configure_iso_anaconda.sh
    kargs: ""
    builder-distro: fedora

- name: Rename and Checksum ISO
  run: |
    mkdir -p output
    mv ${{ steps.build.outputs.iso-dest }} output/my-custom-image.iso
    (cd output && sha256sum my-custom-image.iso | tee my-custom-image.iso-CHECKSUM)
```

### Action Inputs Reference

All inputs for the Titanoboa action:

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `image-ref` | **Yes** | - | Reference to the bootc container image (e.g., `ghcr.io/ublue-os/bluefin:lts`) |
| `livesys` | No | `true` | Install livesys helpers on the rootfs for live environment features |
| `compression` | No | `squashfs` | Compression type: `squashfs` (smaller, slower) or `erofs` (faster) |
| `hook-post-rootfs` | No | `""` | Path to a script to run in the rootfs before it's squashed (see [Hook Scripts](#hook-scripts)) |
| `hook-pre-initramfs` | No | `""` | Path to a script to run before building the initramfs (e.g., to swap kernels) |
| `iso-dest` | No | `${{ github.workspace }}/output.iso` | Where the ISO will be placed |
| `flatpaks-list` | No | `none` | Path to a newline-separated list of Flatpak apps to install in the ISO |
| `container-image` | No | `""` | Container image to install on target system (can differ from the ISO rootfs image) |
| `add-polkit` | No | `true` | Add default polkit rules for the container |
| `kargs` | No | `""` | Comma-separated kernel arguments for the live ISO |
| `builder-distro` | No | `fedora` | Builder distribution: `fedora`, `centos`, or `almalinux` |

#### Action Outputs

| Output | Description |
|--------|-------------|
| `iso-dest` | Absolute path where the ISO was placed |

### Configuration Files

#### Flatpaks List

A text file containing Flatpak application IDs to be preinstalled in your ISO, one per line. Comments are supported with `#`.

**Example** (`flatpaks/system-flatpaks.list`):
```text
# Web browsers
app/org.mozilla.firefox
app/org.mozilla.Thunderbird

# GNOME apps
app/org.gnome.Calculator
app/org.gnome.Calendar
app/org.gnome.TextEditor
app/org.gnome.Loupe

# Themes
runtime/org.gtk.Gtk3theme.adw-gtk3
runtime/org.gtk.Gtk3theme.adw-gtk3-dark

# Development tools
app/com.github.tchx84.Flatseal
app/io.github.flattool.Warehouse
```

**Usage:**
```yaml
with:
  flatpaks-list: ${{ github.workspace }}/flatpaks/system-flatpaks.list
```

#### Hook Scripts

Hook scripts allow you to customize the ISO build process at different stages.

##### `hook-post-rootfs`

A bash script that runs **inside the rootfs** before it's compressed. Use this to:
- Install additional packages
- Configure Anaconda
- Customize the live environment
- Set up default desktop settings
- Disable unnecessary services

**Example** (`iso_files/configure_iso.sh`):
```bash
#!/usr/bin/env bash
set -eoux pipefail

# Remove packages to save space
dnf remove -y google-noto-fonts-all ublue-brew || true

# Configure GNOME defaults for live session
tee /usr/share/glib-2.0/schemas/zz2-org.gnome.shell.gschema.override <<EOF
[org.gnome.shell]
favorite-apps = ['anaconda.desktop', 'org.mozilla.firefox.desktop', 'org.gnome.Nautilus.desktop']
EOF

glib-compile-schemas /usr/share/glib-2.0/schemas

# Disable services not needed in live environment
systemctl disable rpm-ostree-countme.service
systemctl disable tailscaled.service
systemctl disable bootloader-update.service

# Install Anaconda for installation
dnf install -y anaconda-live libblockdev-btrfs
```

**Usage:**
```yaml
with:
  hook-post-rootfs: ${{ github.workspace }}/iso_files/configure_iso.sh
```

##### `hook-pre-initramfs`

A bash script that runs **before generating the initramfs**. Use this to:
- Replace the kernel
- Add custom kernel modules
- Modify dracut configuration

**Example:**
```bash
#!/usr/bin/env bash
set -eoux pipefail

# Install a different kernel
dnf swap -y kernel kernel-lts
```

**Usage:**
```yaml
with:
  hook-pre-initramfs: ${{ github.workspace }}/iso_files/pre_initramfs.sh
```

### Local Usage with Just

For local development and testing, you can build ISOs using the `just` command directly.

#### Installation

1. Install [Just](https://github.com/casey/just):
   ```bash
   # On Fedora/RHEL
   sudo dnf install just
   
   # On Ubuntu/Debian
   sudo snap install --edge --classic just
   ```

2. Install Podman:
   ```bash
   # On Fedora/RHEL
   sudo dnf install podman
   
   # On Ubuntu/Debian
   sudo apt install podman
   ```

#### Basic Build Command

```bash
sudo just build ghcr.io/ublue-os/bluefin:lts
```

This creates `output.iso` in the current directory.

#### Advanced Build Options

The `just build` command accepts multiple parameters:

```bash
just build <image> [livesys] [flatpaks_file] [compression] [extra_kargs] [container_image] [polkit]
```

**Parameters:**
- `image`: Container image reference (required)
- `livesys`: Enable livesys scripts (`1` or `0`, default: `1`)
- `flatpaks_file`: Path to flatpaks list (default: `src/flatpaks.example.txt`)
- `compression`: Compression type (`squashfs` or `erofs`, default: `squashfs`)
- `extra_kargs`: Comma-separated kernel arguments (default: `NONE`)
- `container_image`: Container to install vs. the ISO rootfs image (default: same as `image`)
- `polkit`: Add polkit rules (`1` or `0`, default: `1`)

**Examples:**

```bash
# Build with custom flatpaks list
sudo just build ghcr.io/ublue-os/bluefin:lts 1 ./my-flatpaks.txt

# Build with erofs compression
sudo just build ghcr.io/ublue-os/bluefin:lts 1 src/flatpaks.example.txt erofs

# Build without livesys scripts
sudo just build ghcr.io/ublue-os/bluefin:lts 0

# Build with custom kernel arguments
sudo just build ghcr.io/ublue-os/bluefin:lts 1 src/flatpaks.example.txt squashfs "rd.live.overlay.size=8192"
```

### Environment Variables

Titanoboa can be customized using environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `TITANOBOA_WORKDIR` | `work` | Working directory for build artifacts |
| `TITANOBOA_ISO_ROOT` | `work/iso-root` | ISO root directory |
| `TITANOBOA_BUILDER_DISTRO` | `fedora` | Builder container distribution (`fedora`, `centos`, `almalinux`) |
| `HOOK_post_rootfs` | `""` | Path to post-rootfs hook script |
| `HOOK_pre_initramfs` | `""` | Path to pre-initramfs hook script |

**Example:**

```bash
# Use CentOS Stream 10 builder
TITANOBOA_BUILDER_DISTRO=centos sudo just build ghcr.io/ublue-os/bluefin:lts

# Use custom working directory
TITANOBOA_WORKDIR=/mnt/scratch sudo just build ghcr.io/your-org/your-image:latest

# Use hook scripts
HOOK_post_rootfs=/path/to/script.sh sudo just build ghcr.io/your-org/your-image:latest
```

### Complete Example Workflow

Here's a complete GitHub Actions workflow that builds ISOs for your custom image:

```yaml
name: Build Custom ISO

on:
  workflow_dispatch:
  schedule:
    - cron: '0 0 * * 0'  # Weekly on Sunday

jobs:
  build-iso:
    name: Build ISO
    runs-on: ubuntu-24.04
    permissions:
      contents: read
      packages: read
    
    steps:
      - name: Maximize build space
        uses: ublue-os/remove-unwanted-software@v9
        
      - name: Checkout repository
        uses: actions/checkout@v4
        
      - name: Build ISO
        id: build
        uses: ublue-os/titanoboa@main
        with:
          image-ref: ghcr.io/your-org/your-custom-image:latest
          flatpaks-list: ${{ github.workspace }}/config/flatpaks.list
          hook-post-rootfs: ${{ github.workspace }}/config/configure-iso.sh
          compression: squashfs
          builder-distro: fedora
          
      - name: Rename ISO
        run: |
          mkdir -p output
          mv ${{ steps.build.outputs.iso-dest }} output/custom-image-$(date +%Y%m%d).iso
          (cd output && sha256sum *.iso | tee CHECKSUMS)
          
      - name: Upload ISO
        uses: actions/upload-artifact@v4
        with:
          name: custom-iso
          path: output/
```

### Testing Your ISO

After building your ISO, test it using the built-in VM command:

```bash
# Test in a VM
just vm ./output.iso

# Or use the container-based VM with web VNC
just container-run-vm ./output.iso
```

The `just vm` command launches a QEMU virtual machine with:
- TPM 2.0 support
- UEFI Secure Boot
- Automatic memory allocation
- GPU passthrough (when available)

The `container-run-vm` command:
- Runs QEMU in a container
- Provides web-based VNC access (auto-opens in browser)
- Useful for headless systems or CI environments

### Builder Distribution Support

By default, Titanoboa uses Fedora containers for building tools and dependencies. You can specify different builder distributions:

- **fedora** (default): Uses `quay.io/fedora/fedora:latest` - Best for Fedora-based images
- **centos**: Uses `ghcr.io/hanthor/centos-anaconda-builder:main` - For CentOS Stream 10 / LTS images
- **almalinux**: Uses `quay.io/almalinux/almalinux:10` - For AlmaLinux-based images

**When to use different builders:**
- Use `centos` when building LTS images based on CentOS Stream
- Use `fedora` for standard Fedora-based images (default)
- Use `almalinux` for AlmaLinux-based custom images

**Examples:**

```bash
# GitHub Actions
with:
  builder-distro: centos

# Local with just
TITANOBOA_BUILDER_DISTRO=centos sudo just build ghcr.io/ublue-os/bluefin:lts
```

### Tips and Best Practices

1. **Minimize ISO size**: Remove unnecessary packages in your `hook-post-rootfs` script to keep the ISO smaller
2. **Test incrementally**: Build and test ISOs frequently during development
3. **Use proper compression**: Use `squashfs` for smaller ISOs (better for distribution), `erofs` for faster boot times
4. **Flatpak selection**: Only include essential Flatpaks in your ISO; users can install more after installation
5. **Builder matching**: Use the builder distribution that matches your base image for best compatibility
6. **Clean builds**: Run `just clean` between builds to ensure a fresh start
7. **Hook scripts**: Make your hook scripts idempotent and include error handling
8. **Version pinning**: Pin to specific Titanoboa releases in production workflows (e.g., `ublue-os/titanoboa@v1.0.0`)

### Troubleshooting

**Build fails with "out of space":**
- Free up disk space or use a larger volume
- Remove unnecessary files in your `hook-post-rootfs` script
- Consider using `erofs` compression instead of `squashfs`

**ISO doesn't boot:**
- Verify your base container image is bootc-compatible
- Check that the image exists and is accessible
- Ensure UEFI Secure Boot settings are correct for your hardware

**Flatpaks don't install:**
- Verify Flatpak IDs are correct (use `flatpak search <name>` to find IDs)
- Check network connectivity during build
- Review build logs for specific Flatpak installation errors

**Hook script fails:**
- Ensure scripts have executable permissions: `chmod +x script.sh`
- Use `set -eoux pipefail` at the start of scripts for better error reporting
- Test scripts in a container before using them in builds

## Contributor Metrics

![Alt](https://repobeats.axiom.co/api/embed/ab79f8a8b6ba6111cc7123cbbb8762864c76699f.svg "Repobeats analytics image")
