#!/bin/bash
# Universal package manager wrapper.
# Invoked as the package manager name (pacman, apt, dnf, zypper, apk, emerge).
# Routes to the matching rootless distrobox container, creating it on first use.

declare -A PM_IMAGE=(
    [pacman]="ghcr.io/archlinux/archlinux:latest"
    [apt]="docker.io/library/debian:sid"
    [apt-get]="docker.io/library/debian:sid"
    [dnf]="docker.io/library/fedora:latest"
    [yum]="docker.io/library/fedora:latest"
    [zypper]="docker.io/opensuse/tumbleweed:latest"
    [apk]="docker.io/library/alpine:edge"
    [emerge]="docker.io/gentoo/stage3:latest"
    [nix]="docker.io/nixos/nix:latest"
    [nix-env]="docker.io/nixos/nix:latest"
    [xbps-install]="ghcr.io/void-linux/void-musl-full:latest"
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
    [nix]="nixos"
    [nix-env]="nixos"
    [xbps-install]="void"
)

PM=$(basename "$0")
IMAGE="${PM_IMAGE[$PM]}"
CONTAINER="${PM_CONTAINER[$PM]}"

if [ -z "$IMAGE" ]; then
    echo "pkgwrap: unknown package manager '$PM'" >&2
    exit 1
fi

# If invoked via sudo, run podman as the real user, not root
PODMAN="podman"
DISTROBOX="distrobox"
if [ -n "$SUDO_USER" ]; then
    PODMAN="runuser -u $SUDO_USER -- podman"
    DISTROBOX="runuser -u $SUDO_USER -- distrobox"
fi

run_pm() {
    $PODMAN start "$CONTAINER" >/dev/null 2>&1
    local flags=-i
    [ -t 1 ] && flags=-it
    exec $PODMAN exec --user root "$flags" "$CONTAINER" "$PM" "$@"
}

if $PODMAN container exists "$CONTAINER" 2>/dev/null; then
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
$DISTROBOX create --image "$IMAGE" --name "$CONTAINER" --no-entry --yes \
    --post-init-hooks "bash /run/host/usr/lib/ark/distrobox-setup"
run_pm "$@"
