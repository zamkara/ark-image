#!/bin/bash
# Host pacman wrapper for the immutable system (real pacman is removed).
#
# - If the 'archlinux' distrobox container already exists, run pacman inside it
#   (via the container's passwordless sudo — no host sudo needed).
# - If it does not exist yet, OFFER to create it. /etc/archlinux is written by
#   the installer (alga) with the ark-orundum image tag matching THIS system's
#   variant, so the created container always matches the installed variant.
#   The image is pulled on first creation.

if podman container exists archlinux 2>/dev/null; then
    exec distrobox enter archlinux -- sudo pacman "$@"
fi

echo "Distrobox container 'archlinux' belum ada di sistem ini."
if [ -t 0 ]; then
    read -rp "Buat sekarang? Image varian sistem akan di-unduh. [Y/n]: " ans
    case "${ans,,}" in
        n|no) echo "Dibatalkan."; exit 1 ;;
    esac
fi

if [ ! -f /etc/archlinux ]; then
    echo "Error: /etc/archlinux tidak ditemukan — tidak tahu image varian yang benar." >&2
    exit 1
fi

echo "Membuat container 'archlinux' (mengunduh image, mohon tunggu)..."
bash /etc/archlinux
exec distrobox enter archlinux -- sudo pacman "$@"
