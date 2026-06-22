#!/bin/bash
# Universal package manager wrapper.
# Invoked as the package manager name (pacman, apt, dnf, zypper, apk, emerge).
# Routes to the matching rootless distrobox container, creating it on first use.

declare -A PM_IMAGE=(
    [pacman]="ghcr.io/archlinux/archlinux:latest"
    [apt]="docker.io/library/debian:latest"
    [apt-get]="docker.io/library/debian:latest"
    [dnf]="docker.io/library/fedora:latest"
    [yum]="docker.io/library/fedora:latest"
    [zypper]="docker.io/opensuse/tumbleweed:latest"
    [apk]="docker.io/library/alpine:latest"
    [emerge]="docker.io/gentoo/stage3:latest"
)

declare -A PM_CONTAINER=(
    [pacman]="archlinux"
    [apt]="debian"
    [apt-get]="debian"
    [dnf]="fedora"
    [yum]="fedora"
    [zypper]="opensuse"
    [apk]="alpine"
    [emerge]="gentoo"
)

PM=$(basename "$0")
IMAGE="${PM_IMAGE[$PM]}"
CONTAINER="${PM_CONTAINER[$PM]}"

if [ -z "$IMAGE" ]; then
    echo "pkgwrap: unknown package manager '$PM'" >&2
    exit 1
fi

run_pm() {
    podman start "$CONTAINER" >/dev/null 2>&1
    local flags=-i
    [ -t 1 ] && flags=-it
    exec podman exec --user root "$flags" "$CONTAINER" "$PM" "$@"
}

if podman container exists "$CONTAINER" 2>/dev/null; then
    run_pm "$@"
fi

echo "Container '$CONTAINER' doesn't exist on this system."
if [ -t 0 ]; then
    read -rp "Create it now? The image'll be downloaded. [Y/n]: " ans
    case "${ans,,}" in
        n|no) echo "Cancelled."; exit 1 ;;
    esac
fi

echo "Creating container '$CONTAINER', downloading image..."
distrobox create --image "$IMAGE" --name "$CONTAINER" --no-entry --yes >/dev/null 2>&1
run_pm "$@"
