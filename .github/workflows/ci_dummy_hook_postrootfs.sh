#!/usr/bin/env bash

YAI_LATEST=$(curl -fSsL https://api.github.com/repos/ublue-os/yai/releases/latest | jq -r --arg arch $(arch) '.assets[] | select(.name | match("yai-.*."+$arch+".rpm")) | .browser_download_url')
{ which dnf5 || which dnf; } 2>/dev/null install -y $YAI_LATEST
mkdir -p /etc/gnome-initial-setup
tee /etc/gnome-initial-setup/vendor.conf <<EOF
[live_user pages]
skip=privacy;timezone;software;goa

[install]
application=yai.desktop
EOF
mkdir -p /etc/xdg/
tee /etc/xdg/plasma-welcomerc <<EOF
[General]
LiveEnvironment=true
LiveInstaller=yai
EOF