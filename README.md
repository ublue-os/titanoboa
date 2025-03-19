# Titanoboa (Alpha)

A [bootc](https://github.com/bootc-dev/bootc) installer that eats anacondas.

This is an experiment to see how far we can get building our own ISOs

The objective is to:
- Make our own ISO from scratch
- Have it booting a live bootc ISO
- Install any image off of that

## Building a Live ISO

```bash
just build ghcr.io/ublue-os/bluefin:lts
just vm ./output.iso
```

## TODO
- [ ] Include flatpaks in the rootfs
- [ ] FAST /var/lib/containers storage
- [ ] UEFI support
- [ ] Have an installer for the Live ISO
- [ ] Different names for each image
