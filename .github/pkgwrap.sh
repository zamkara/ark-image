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
IMAGE_MAP[apk]="docker.io/library/alpine:latest"
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

# ── Color helpers ─────────────────────────────────────────────────────────────
if [ -t 1 ]; then
    readonly CYAN='\033[1;36m'
    readonly GREEN='\033[1;32m'
    readonly RED='\033[1;31m'
    readonly RESET='\033[0m'
else
    readonly CYAN=''
    readonly GREEN=''
    readonly RED=''
    readonly RESET=''
fi

# ── Spinner ───────────────────────────────────────────────────────────────────
spin_run() {
    local msg=$1
    shift
    local dots='. .. ...'
    local rc=0
    local errlog

    errlog=$(mktemp /tmp/pkgwrap-err-XXXXXX 2>/dev/null) || errlog="/tmp/pkgwrap-err.log"

    printf "%s  " "$msg"
    "$@" >/dev/null 2>"$errlog" &
    local pid=$!

    while kill -0 $pid 2>/dev/null; do
        local d
        for d in $dots; do
            printf "\r%s%s" "$msg" "$d"
            kill -0 $pid 2>/dev/null || break
            sleep 0.3
        done
    done

    wait $pid || rc=$?

    if [ $rc -eq 0 ]; then
        printf "\r%s ${GREEN}✔ done${RESET}\n" "$msg"
    else
        printf "\r%s ${RED}✗ failed${RESET}\n" "$msg"
        cat "$errlog" 2>/dev/null
    fi
    rm -f "$errlog"
    return $rc
}

# ── Container helpers ─────────────────────────────────────────────────────────
container_exists() {
    run_as_user distrobox list 2>/dev/null | grep -qw "$CONTAINER"
}

CREATED_CONTAINER=false

ensure_container() {
    if container_exists; then
        return 0
    fi

    echo -e "container not found: ${CYAN}$CONTAINER${RESET} (${IMAGE})"

    if [ -z "${DBX_NON_INTERACTIVE:-}" ] && [ -t 0 ]; then
        read -p "Create? [Y/n] " -r
    else
        REPLY=y
    fi

    if [[ ! $REPLY =~ ^[Yy]$ ]] && [ -n "$REPLY" ]; then
        echo -e "aborted"
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

    if ! spin_run "preparing container environment" run_as_user distrobox create "${create_args[@]}"; then
        echo -e "  ${RED}container init failed — distrobox logs above may have details${RESET}" >&2
        exit 1
    fi
    CREATED_CONTAINER=true
}

# ── Operation detection ─────────────────────────────────────────────────────────
detect_op() {
    local pm=$1; shift
    local args=("$@")

    case "$pm" in
        apt|apt-get)
            for arg in "${args[@]}"; do
                case "$arg" in
                    -*) continue ;;
                    install)                echo "install"; return ;;
                    remove|purge|autoremove) echo "remove";  return ;;
                    update|upgrade|full-upgrade|dist-upgrade) echo "upgrade"; return ;;
                    search|show)            echo "search";  return ;;
                    *)                      echo "install"; return ;;
                esac
            done
            echo "noop"
            ;;
        dnf|yum)
            for arg in "${args[@]}"; do
                case "$arg" in
                    -*) continue ;;
                    install|groupinstall|localinstall) echo "install"; return ;;
                    remove|erase|autoremove)  echo "remove";  return ;;
                    update|upgrade|distro-sync|check-update) echo "upgrade"; return ;;
                    search|provides|whatprovides) echo "search"; return ;;
                    *) echo "noop"; return ;;
                esac
            done
            echo "noop"
            ;;
        pacman)
            local has_sync=false has_upgrade_file=false
            local has_remove=false has_search=false has_query=false
            for arg in "${args[@]}"; do
                case "$arg" in
                    --noconfirm|--needed|--ask|--overwrite|--color|--noprogressbar|--noscriptlet|--print|--quiet|--verbose|--debug|--confirm|--disable-download-timeout|--gpgdir|--keyserver|--print-format|--sysroot|--root|--dbpath|--cachedir|--hookdir|--logfile)
                        continue ;;
                    -S|--sync)          has_sync=true ;;
                    -S*)                has_sync=true ;;
                    -U|--upgrade)       has_upgrade_file=true ;;
                    -U*)                has_upgrade_file=true ;;
                    -R*)                has_remove=true ;;
                    --remove)           has_remove=true ;;
                    -[sS][sS]*)         has_search=true ;;
                    --search)           has_search=true ;;
                    -Q*|--query)        has_query=true ;;
                    -F*|--files)        has_search=true ;;
                esac
            done
            $has_search && { echo "search";  return; }
            $has_query  && { echo "noop";    return; }
            $has_remove && { echo "remove";  return; }
            $has_sync || $has_upgrade_file && { echo "install"; return; }
            echo "noop"
            ;;
        zypper)
            for arg in "${args[@]}"; do
                case "$arg" in
                    -*) continue ;;
                    install|in) echo "install"; return ;;
                    remove|rm)  echo "remove";  return ;;
                    update|up|dup) echo "upgrade"; return ;;
                    search|se)  echo "search";  return ;;
                    *)          echo "noop";    return ;;
                esac
            done
            echo "noop"
            ;;
        apk)
            for arg in "${args[@]}"; do
                case "$arg" in
                    -*) continue ;;
                    add)            echo "install"; return ;;
                    del)            echo "remove";  return ;;
                    update|upgrade) echo "upgrade"; return ;;
                    search)         echo "search";  return ;;
                    info|list)      echo "noop";    return ;;
                    *)              echo "noop";    return ;;
                esac
            done
            echo "noop"
            ;;
        emerge)
            for arg in "${args[@]}"; do
                case "$arg" in
                    --unmerge|-C|--depclean|-c)
                        echo "remove"; return ;;
                    --sync)
                        echo "upgrade"; return ;;
                    --search|-s|--pattern)
                        echo "search"; return ;;
                    -*)
                        continue ;;
                    *)
                        echo "install"; return ;;
                esac
            done
            echo "noop"
            ;;
        xbps-install)
            local has_remove=false has_search=false
            local has_sync_flag=false has_update_flag=false
            local has_positional=false
            for arg in "${args[@]}"; do
                case "$arg" in
                    -r|--remove)  has_remove=true ;;
                    -s|--search)  has_search=true ;;
                    -S|--sync)    has_sync_flag=true ;;
                    -u|--update)  has_update_flag=true ;;
                    -Su|-Su*)     has_sync_flag=true; has_update_flag=true ;;
                    -*)           ;;
                    *)            has_positional=true ;;
                esac
            done
            $has_search && { echo "search";  return; }
            $has_remove && { echo "remove";  return; }
            if $has_positional; then
                echo "install"
                return
            fi
            $has_update_flag && { echo "upgrade"; return; }
            $has_sync_flag   && { echo "upgrade"; return; }
            echo "install"
            ;;
        *)
            echo "noop"
            ;;
    esac
}

# ── Package name extraction ───────────────────────────────────────────────────
extract_pkg_names() {
    local op=$1; shift
    local pkgs=()
    local arg

    case "$PM" in
        xbps-install|emerge)
            for arg in "$@"; do
                [[ -z "$arg" ]] && continue
                [[ "$arg" == -* ]] && continue
                pkgs+=("$arg")
            done
            ;;
        pacman)
            local capturing=false
            for arg in "$@"; do
                [[ -z "$arg" ]] && continue
                if ! $capturing; then
                    case "$arg" in
                        -[sS]*|-U*|--sync|--upgrade)
                            [ "$op" = "install" ] && capturing=true ;;
                        -R*|--remove)
                            [ "$op" = "remove" ] && capturing=true ;;
                    esac
                    continue
                fi
                [[ "$arg" == -- ]] && continue
                [[ "$arg" == -* ]] && continue
                pkgs+=("$arg")
            done
            ;;
        *)
            local found_subcmd=false
            for arg in "$@"; do
                [[ -z "$arg" ]] && continue
                if ! $found_subcmd; then
                    case "$arg" in
                        -*) continue ;;
                        install|add|in|groupinstall|localinstall|--install)
                            [ "$op" = "install" ] && found_subcmd=true ;;
                        remove|purge|autoremove|erase|del|rm)
                            [ "$op" = "remove" ] && found_subcmd=true ;;
                    esac
                    continue
                fi
                [[ "$arg" == -- ]] && continue
                [[ "$arg" == -* ]] && continue
                case "$arg" in
                    install|add|remove|del|purge|update|upgrade|full-upgrade|dist-upgrade|\
                    autoremove|clean|autoclean|search|show|query|info|profile|\
                    --help|--version|-h|-V|-R|-Q|-U|-F|-s|\
                    --remove|--upgrade|--query|--search|--info|--clean|in|rm|del)
                        continue ;;
                esac
                pkgs+=("$arg")
            done
            ;;
    esac

    printf '%s\n' "${pkgs[@]}"
}

extract_packages() {
    local op
    op=$(detect_op "$PM" "$@")
    [[ "$op" != "install" ]] && return 0
    extract_pkg_names "install" "$@"
}

prompt_export() {
    local pkg=$1 reply succeeded=false

    echo
    echo "Export '$pkg'?"
    echo -e "[${RED}N${RESET}] Nope  [${GREEN}A${RESET}] App  [${GREEN}B${RESET}] Only Binary executable"
    read -n1 -s -r reply
    echo
    [ -t 1 ] && clear
    case "$reply" in
        [Aa]*)
            if run_as_user distrobox enter "$CONTAINER" -- distrobox-export --app "$pkg" >/dev/null 2>/dev/null; then
                succeeded=true
            elif run_as_user distrobox enter "$CONTAINER" -- distrobox-export --bin "/usr/bin/$pkg" >/dev/null 2>/dev/null; then
                succeeded=true
            fi
            ;;
        [Bb]*)
            if run_as_user distrobox enter "$CONTAINER" -- distrobox-export --bin "/usr/bin/$pkg" >/dev/null 2>/dev/null; then
                succeeded=true
            fi
            ;;
        *) echo "skipped"; return ;;
    esac

    if $succeeded; then
        echo -e "${GREEN}✔${RESET} installed $pkg"
    else
        echo -e "installed $pkg, ${RED}✗${RESET} export failed"
    fi
}

prompt_cleanup() {
    local pkg=$1
    local reply

    echo
    echo "Cleanup '$pkg'?"
    echo -e "[${RED}N${RESET}] Nope  [${GREEN}Y${RESET}] Yes, delete exported files"
    read -n1 -s -r reply
    echo
    [ -t 1 ] && clear

    case "$reply" in
        [Yy]) ;;
        *) echo "skipped"; return ;;
    esac

    # Try distrobox-export --delete first, then force-remove host files
    run_as_user distrobox enter -n "$CONTAINER" -- distrobox-export --app "$pkg" -d >/dev/null 2>/dev/null || true
    run_as_user distrobox enter -n "$CONTAINER" -- distrobox-export --bin "/usr/bin/$pkg" -d >/dev/null 2>/dev/null || true
    run_as_user bash -c 'rm -f "$HOME/.local/share/applications/$1-$2".desktop' _ "$CONTAINER" "$pkg" >/dev/null 2>/dev/null || true
    echo -e "${GREEN}✔${RESET} cleaned $pkg"
}

# ── Main ──────────────────────────────────────────────────────────────────────
ensure_container

if $CREATED_CONTAINER && [ -t 1 ]; then
    clear
fi

run_as_user distrobox enter "$CONTAINER" -- sudo -E "$PM" "$@"
rc=$?

if [ $rc -eq 0 ]; then
    op=$(detect_op "$PM" "$@")
    if [[ "$op" == "install" ]]; then
        mapfile -t packages < <(extract_pkg_names "install" "$@")
        if [ ${#packages[@]} -gt 0 ] && [ -t 1 ]; then
            echo -e "${GREEN}✔${RESET} done"
            [ -t 1 ] && clear
            i=0
            total=${#packages[@]}
            for pkg in "${packages[@]}"; do
                prompt_export "$pkg"
                i=$((i + 1))
                if [ $i -lt $total ] && [ -t 1 ]; then
                    clear
                fi
            done
        elif [ ${#packages[@]} -gt 0 ]; then
            for pkg in "${packages[@]}"; do
                prompt_export "$pkg"
            done
        fi
    elif [[ "$op" == "remove" ]]; then
        mapfile -t packages < <(extract_pkg_names "remove" "$@")
        if [ ${#packages[@]} -gt 0 ] && [ -t 1 ]; then
            echo -e "${GREEN}✔${RESET} done"
            [ -t 1 ] && clear
            i=0
            total=${#packages[@]}
            for pkg in "${packages[@]}"; do
                prompt_cleanup "$pkg"
                i=$((i + 1))
                if [ $i -lt $total ] && [ -t 1 ]; then
                    clear
                fi
            done
        elif [ ${#packages[@]} -gt 0 ]; then
            for pkg in "${packages[@]}"; do
                prompt_cleanup "$pkg"
            done
        fi
    fi
fi

exit $rc
