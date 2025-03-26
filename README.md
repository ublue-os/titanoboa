# Titanoboa (Alpha)

A [bootc](https://github.com/bootc-dev/bootc) installer designed to install an image as quickly as possible.


## Mission

This is an experiment to see how far we can get building our own ISOs. The objective is to:

- Generate a LiveCD so users can try out an image before committing
- Install the image and flatpaks to a selected disk with minimal user-input
- Basically be an MVP for `bootc install` 

## Why?

Waiting for existing installers to move to cloud native is untenable, let's see if we can remove that external dependency forever. 😈

## Components

- LiveCD (done in this repository)
- [ublue-os/yai](https://github.com/ublue-os/yai) - Tauri bootc install wrapper

## Building a Live ISO

```bash
just build ghcr.io/ublue-os/bluefin:lts
just vm ./output.iso
```

## Contributor Metrics

![Alt](https://repobeats.axiom.co/api/embed/ab79f8a8b6ba6111cc7123cbbb8762864c76699f.svg "Repobeats analytics image")
