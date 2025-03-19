#!/bin/sh

USERNAME=livecd

# Check if user already exists
if ! id "$USERNAME" >/dev/null 2>&1; then
  echo "Creating $USERNAME user..."

  # Create the user with home directory
  useradd -m -G wheel -s /bin/bash "$USERNAME"

  # Set no password (auto-login possible)
  echo "$USERNAME" | passwd "$USERNAME" --stdin

  # Allow passwordless sudo
  echo "$USERNAME ALL=(ALL) NOPASSWD: ALL" >/etc/sudoers.d/90-$USERNAME
  chmod 0440 /etc/sudoers.d/90-$USERNAME
else
  echo "$USERNAME already exists, skipping creation."
fi
