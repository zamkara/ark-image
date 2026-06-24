#!/usr/bin/env bash
set -euo pipefail

PM=$(basename "$0")

# ── Configuration ─────────────────────────────────────────────────────────────
declare -A IMAGE_MAP
IMAGE_MAP[pacman]="ghcr.io/archlinux/archlinux:latest"
IMAGE_MAP[apt]="docker.io/library/debian:sid"
IMAGE_MAP[apt-get]="docker.io/library/debian:sid"
IMAGE_MAP[dnf]="docker.io/library/fedora:rawhide"
IMAGE_MAP[yum]="docker.io/library/fedora:rawhide"
IMAGE_MAP[zypper]="docker.io/opensuse/tumbleweed:latest"
IMAGE_MAP[apk]="docker.io/library/alpine:edge"
IMAGE_MAP[emerge]="docker.io/gentoo/stage3:latest"
IMAGE_MAP[nix]="docker.io/nixos/nix:latest"
IMAGE_MAP[nix-env]="docker.io/nixos/nix:latest"
IMAGE_MAP[xbps-install]="ghcr.io/void-linux/void-musl-full:latest"

declare -A CONTAINER_MAP
CONTAINER_MAP[pacman]="archlinux"
CONTAINER_MAP[apt]="debian"
CONTAINER_MAP[apt-get]="debian"
CONTAINER_MAP[dnf]="fedora"
CONTAINER_MAP[yum]="fedora"
CONTAINER_MAP[zypper]="opensuse"
CONTAINER_MAP[apk]="alpine"
CONTAINER_MAP[emerge]="gentoo"
CONTAINER_MAP[nix]="nixos"
CONTAINER_MAP[nix-env]="nixos"
CONTAINER_MAP[xbps-install]="void"

IMAGE="${IMAGE_MAP[$PM]:-}"
CONTAINER="${CONTAINER_MAP[$PM]:-}"

if [ -z "$IMAGE" ]; then
    echo "pkgwrap: unknown package manager '$PM'" >&2
    echo "pkgwrap: invoke via a symlink named after a supported PM" >&2
    exit 1
fi

# ── Detect sudo & run helper ──────────────────────────────────────────────────
run_as_user() {
    if [ -n "${SUDO_UID:-}" ]; then
        systemd-run --user -M "${SUDO_UID}@.host" --wait --collect --pipe --quiet -- "$@"
    else
        "$@"
    fi
}

# ── Container helpers ─────────────────────────────────────────────────────────
container_exists() {
    run_as_user distrobox list 2>/dev/null | grep -qw "$CONTAINER"
}

ensure_container() {
    if container_exists; then
        return 0
    fi

    echo "Container '$CONTAINER' (for $PM) does not exist yet."
    echo "Image: $IMAGE"
    echo

    if [ -z "${DBX_NON_INTERACTIVE:-}" ]; then
        read -p "Create container '$CONTAINER'? [Y/n] " -r
    else
        REPLY=y
    fi

    if [[ ! $REPLY =~ ^[Yy]$ ]] && [ -n "$REPLY" ]; then
        echo "pkgwrap: aborted by user" >&2
        exit 1
    fi

    local create_args=(
        --image "$IMAGE"
        --name "$CONTAINER"
        --init-hooks "bash /run/host/usr/lib/ark/distrobox-setup"
    )

    if [[ "$PM" == "apt" || "$PM" == "apt-get" ]]; then
        local pre_init="mkdir -p /etc/apt/apt.conf.d && printf 'Dpkg::Use-Pty \"0\";\n' > /etc/apt/apt.conf.d/99-no-pty"
        create_args+=(--pre-init-hooks "$pre_init")
        create_args+=(--additional-flags "--env DEBIAN_FRONTEND=noninteractive")
    fi

    echo "Creating container '$CONTAINER'..."
    run_as_user distrobox create "${create_args[@]}"
    echo "Container '$CONTAINER' created."
}

# ── Package name extraction ───────────────────────────────────────────────────
extract_packages() {
    local install_found=false
    local pkgs=()
    local arg

    # emerge passes package names as direct arguments (no subcommand)
    if [[ "$PM" == "emerge" ]]; then
        for arg in "$@"; do
            [[ "$arg" == -* ]] && continue
            pkgs+=("$arg")
        done
        printf '%s\n' "${pkgs[@]}"
        return
    fi

    for arg in "$@"; do
        if ! $install_found; then
            case "$arg" in
                install|add|-S|-i|--install|in|-U)
                    install_found=true
                    ;;
                -[sS]*|-U*)
                    if [ ${#arg} -gt 2 ]; then
                        install_found=true
                    fi
                    ;;
            esac
            continue
        fi

        [[ "$arg" == "--" ]] && continue
        [[ "$arg" == -* ]] && continue

        case "$arg" in
            install|add|remove|del|purge|update|upgrade|full-upgrade|dist-upgrade|\
            autoremove|clean|autoclean|search|show|query|info|profile|\
            --help|--version|-h|-V|-R|-Q|-U|-F|-s|\
            --remove|--upgrade|--query|--search|--info|--clean|in|rm|del)
                continue
                ;;
        esac

        pkgs+=("$arg")
    done

    printf '%s\n' "${pkgs[@]}"
}

prompt_export() {
    local pkg=$1
    local reply opt

    echo
    echo "Export '$pkg'?"
    echo -e "  [\033[1;31mN\033[0m] Nope  [\033[1;32mA\033[0m] App  [\033[1;32mB\033[0m] Only Binary executable"
    read -p "→ " -r reply
    case "$reply" in
        [Aa]*) opt="--app" ;;
        [Bb]*) opt="--bin" ;;
        *)     echo "→ skipped"; return ;;
    esac

    echo "→ $pkg exported as $opt ✓"
    run_as_user distrobox enter "$CONTAINER" -- distrobox-export "$opt" "$pkg"
}

# ── Main ──────────────────────────────────────────────────────────────────────
ensure_container

run_as_user distrobox enter "$CONTAINER" -- sudo -E "$PM" "$@"
rc=$?

# ── Post-install export dialog ────────────────────────────────────────────────
if [ $rc -eq 0 ]; then
    mapfile -t packages < <(extract_packages "$@")
    for pkg in "${packages[@]}"; do
        prompt_export "$pkg"
    done
fi

exit $rc
