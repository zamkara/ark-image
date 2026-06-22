#!/bin/bash
# Host pacman wrapper. Real pacman is removed on the immutable host; package
# management happens inside the 'archlinux' distrobox container.
#
# We run pacman as the container's root via `podman exec --user root` — this
# needs NO sudo (neither on the host nor inside the container), so it is immune
# to the setuid bit being stripped (rootless podman maps container uid 0 to the
# invoking user via the user namespace, giving full in-container privileges).
#
# /etc/archlinux is written by the installer (alga) with the ark-orundum image
# tag matching THIS system's variant, so a freshly created container always
# matches the installed variant. The image is pulled on first creation.

run_pacman() {
    podman start archlinux >/dev/null 2>&1
    local flags=-i
    [ -t 1 ] && flags=-it
    exec podman exec --user root "$flags" archlinux pacman "$@"
}

if podman container exists archlinux 2>/dev/null; then
    run_pacman "$@"
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
run_pacman "$@"
