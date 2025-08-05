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

## Building a Live ISO

```bash
just build ghcr.io/ublue-os/bluefin:lts
just vm ./output.iso
```

### Builder Distribution Support

By default, Titanoboa uses Fedora containers for building tools and dependencies. You can now specify different builder distributions using the `TITANOBOA_BUILDER_DISTRO` environment variable:

- **fedora** (default): Uses `quay.io/fedora/fedora:latest`
- **centos**: Uses `quay.io/centos/centos:stream9`
- **almalinux**: Uses `quay.io/almalinux/almalinux:9`

Examples:
```bash
# Use CentOS Stream 9 for building
TITANOBOA_BUILDER_DISTRO=centos just build ghcr.io/ublue-os/bluefin:lts

# Use AlmaLinux 9 for building
TITANOBOA_BUILDER_DISTRO=almalinux just build ghcr.io/ublue-os/bluefin:lts

# Use Fedora (default)
just build ghcr.io/ublue-os/bluefin:lts
```

## Contributor Metrics

![Alt](https://repobeats.axiom.co/api/embed/ab79f8a8b6ba6111cc7123cbbb8762864c76699f.svg "Repobeats analytics image")
