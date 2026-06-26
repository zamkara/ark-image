#!/usr/bin/env bash
set -euo pipefail

PM=$(basename "$0")

# ── Configuration ─────────────────────────────────────────────────────────────
declare -A IMAGE_MAP
IMAGE_MAP[pacman]="ghcr.io/archlinux/archlinux:latest"
IMAGE_MAP[apt]="docker.io/library/debian:latest"
IMAGE_MAP[apt-get]="docker.io/library/debian:latest"
IMAGE_MAP[dnf]="docker.io/library/fedora:latest"
IMAGE_MAP[yum]="docker.io/library/fedora:latest"
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

    local runtime=""
    if   command -v podman &>/dev/null; then runtime=podman
    elif command -v docker &>/dev/null; then runtime=docker
    fi

    if [ -n "$runtime" ]; then
        if ! run_as_user "$runtime" image exists "$IMAGE" 2>/dev/null; then
            spin_run "pulling image" run_as_user "$runtime" pull "$IMAGE"
        fi
    fi

    if ! spin_run "preparing container" run_as_user distrobox create "${create_args[@]}"; then
        echo -e "  ${RED}container init failed — distrobox logs above may have details${RESET}" >&2
        exit 1
    fi

    if ! spin_run "initializing container" run_as_user distrobox enter "$CONTAINER" -- true; then
        echo -e "  ${RED}container initialization failed — distrobox may need updated packages${RESET}" >&2
        run_as_user distrobox rm --force "$CONTAINER" 2>/dev/null || true
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

# ── File resolution ──────────────────────────────────────────────────────────
# Query the package manager inside the container for files owned by a package.
list_pkg_files() {
    local pkg=$1
    case "$PM" in
        dnf|yum|zypper)
            run_as_user distrobox enter -n "$CONTAINER" -- rpm -ql "$pkg" 2>/dev/null ;;
        apt|apt-get)
            run_as_user distrobox enter -n "$CONTAINER" -- dpkg -L "$pkg" 2>/dev/null ;;
        pacman)
            run_as_user distrobox enter -n "$CONTAINER" -- pacman -Qlq "$pkg" 2>/dev/null ;;
        apk)
            run_as_user distrobox enter -n "$CONTAINER" -- apk info -L "$pkg" 2>/dev/null ;;
        xbps-install)
            run_as_user distrobox enter -n "$CONTAINER" -- xbps-query -f "$pkg" 2>/dev/null ;;
        emerge)
            run_as_user distrobox enter -n "$CONTAINER" -- equery files "$pkg" 2>/dev/null ;;
        *)
            ;;
    esac
}

# Full paths to .desktop files owned by $pkg (one per line).
resolve_desktop_paths() {
    local pkg=$1
    list_pkg_files "$pkg" | grep -E '/applications/.*\.desktop$'
}

# Desktop-file IDs (basename, no .desktop) for host-side filename matching.
resolve_desktop_ids() {
    local pkg=$1
    resolve_desktop_paths "$pkg" | sed -E 's#.*/##; s#\.desktop$##'
}

# Full paths to binaries (under /usr/bin/ or /bin/) owned by $pkg.
resolve_bin_paths() {
    local pkg=$1
    list_pkg_files "$pkg" | grep -E '^/(usr/)?bin/'
}

prompt_export() {
    local pkg=$1 reply succeeded=false
    local desktop_paths=() desktop_ids=() bin_paths=() path

    mapfile -t desktop_paths < <(resolve_desktop_paths "$pkg")
    mapfile -t desktop_ids < <(resolve_desktop_ids "$pkg")
    mapfile -t bin_paths < <(resolve_bin_paths "$pkg")

    echo
    echo "Export '$pkg'?"
    echo -e "[${RED}N${RESET}] Nope  [${GREEN}A${RESET}] App  [${GREEN}B${RESET}] Only Binary executable"
    read -n1 -s -r reply
    echo
    :
    case "$reply" in
        [Aa]*)
            for path in "${desktop_paths[@]}"; do
                if run_as_user distrobox enter "$CONTAINER" -- distrobox-export --app "$path" >/dev/null 2>/dev/null; then
                    succeeded=true
                fi
            done
            if ! $succeeded && run_as_user distrobox enter "$CONTAINER" -- distrobox-export --app "$pkg" >/dev/null 2>/dev/null; then
                succeeded=true
            fi
            if ! $succeeded; then
                for path in "${bin_paths[@]}"; do
                    if run_as_user distrobox enter "$CONTAINER" -- distrobox-export --bin "$path" >/dev/null 2>/dev/null; then
                        succeeded=true
                    fi
                done
            fi
            if ! $succeeded && run_as_user distrobox enter "$CONTAINER" -- distrobox-export --bin "/usr/bin/$pkg" >/dev/null 2>/dev/null; then
                succeeded=true
            fi
            ;;
        [Bb]*)
            for path in "${bin_paths[@]}"; do
                if run_as_user distrobox enter "$CONTAINER" -- distrobox-export --bin "$path" >/dev/null 2>/dev/null; then
                    succeeded=true
                fi
            done
            if ! $succeeded && run_as_user distrobox enter "$CONTAINER" -- distrobox-export --bin "/usr/bin/$pkg" >/dev/null 2>/dev/null; then
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
    local desktop_paths=() desktop_ids=() bin_paths=() path

    mapfile -t desktop_paths < <(resolve_desktop_paths "$pkg")
    mapfile -t desktop_ids < <(resolve_desktop_ids "$pkg")
    mapfile -t bin_paths < <(resolve_bin_paths "$pkg")

    for path in "${desktop_paths[@]}"; do
        run_as_user distrobox enter -n "$CONTAINER" -- distrobox-export --app "$path" -d >/dev/null 2>/dev/null || true
    done
    run_as_user distrobox enter -n "$CONTAINER" -- distrobox-export --app "$pkg" -d >/dev/null 2>/dev/null || true
    for path in "${bin_paths[@]}"; do
        run_as_user distrobox enter -n "$CONTAINER" -- distrobox-export --bin "$path" -d >/dev/null 2>/dev/null || true
    done
    run_as_user distrobox enter -n "$CONTAINER" -- distrobox-export --bin "/usr/bin/$pkg" -d >/dev/null 2>/dev/null || true

    # Force-remove leftover host-side desktop files for this container.
    run_as_user bash -c '
        home="$1"; container="$2"; pkg="$3"; shift 3
        appdir="$home/.local/share/applications"
        for id in "$@"; do
            rm -f "$appdir/${container}-${id}.desktop"
        done
        for f in "$appdir/${container}-"*"${pkg}"*.desktop; do
            [ -e "$f" ] && rm -f "$f"
        done
    ' _ "$HOME" "$CONTAINER" "$pkg" "${desktop_ids[@]}" >/dev/null 2>/dev/null || true

    echo -e "${GREEN}✔${RESET} cleaned $pkg"
}

# ── Main ──────────────────────────────────────────────────────────────────────
ensure_container

op=$(detect_op "$PM" "$@")

# For remove: delete desktop files BEFORE package removal, while they're
# still available inside the container for resolve_desktop_ids.
if [[ "$op" == "remove" ]]; then
    mapfile -t packages < <(extract_pkg_names "remove" "$@")
    for pkg in "${packages[@]}"; do
        prompt_cleanup "$pkg"
    done
fi

run_as_user distrobox enter "$CONTAINER" -- sudo -E "$PM" "$@"
rc=$?

if [ $rc -eq 0 ] && [[ "$op" == "install" ]]; then
    mapfile -t packages < <(extract_pkg_names "install" "$@")
    if [ ${#packages[@]} -gt 0 ] && [ -t 1 ]; then
        echo -e "${GREEN}✔${RESET} done"
        for pkg in "${packages[@]}"; do
            prompt_export "$pkg"
        done
    elif [ ${#packages[@]} -gt 0 ]; then
        for pkg in "${packages[@]}"; do
            prompt_export "$pkg"
        done
    fi
fi

exit $rc
