#!/bin/bash
# Host pacman wrapper: ensure the arch distrobox exists (created on demand,
# image pulled on first use), then run pacman as root inside it. distrobox
# configures passwordless sudo inside the container, so no host sudo needed.
[ -f /etc/archlinux ] && bash /etc/archlinux
exec distrobox enter archlinux -- sudo pacman "$@"
