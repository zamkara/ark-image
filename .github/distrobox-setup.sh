#!/usr/bin/env bash
set -euo pipefail

readonly ARK_DIR="/usr/lib/ark"
readonly EXPORT_HELPER="$ARK_DIR/distrobox-export"
readonly UID_TARGET=1000

USER_NAME=$(getent passwd $UID_TARGET | cut -d: -f1)
USER_HOME=$(getent passwd $UID_TARGET | cut -d: -f6)

if [ -z "$USER_NAME" ]; then
    echo "distrobox-setup: user with UID $UID_TARGET not found" >&2
    exit 1
fi

mkdir -p "$ARK_DIR"
cat > "$EXPORT_HELPER" << HELPER
#!/usr/bin/env bash
set -euo pipefail

readonly USER_NAME="$USER_NAME"
readonly USER_HOME="$USER_HOME"
readonly USER_UID=$UID_TARGET
readonly CONTAINER_ID=$(hostname)

case "\${1:-}" in
    --app|--bin)
        export CONTAINER_ID
        export XDG_DATA_DIRS=/usr/local/share:/usr/share
        export XDG_RUNTIME_DIR=/run/user/\$USER_UID
        export HOME=\$USER_HOME

        runuser -u "\$USER_NAME" \
            env CONTAINER_ID="\$CONTAINER_ID" \
                XDG_DATA_DIRS=/usr/local/share:/usr/share \
                XDG_RUNTIME_DIR=/run/user/\$USER_UID \
                HOME="\$USER_HOME" \
            -- distrobox-export "\$@" 2>/dev/null \
        || true
        ;;
    *)
        echo "Usage: \$0 --app <name> | --bin <name>"
        exit 1
        ;;
esac
HELPER
chmod +x "$EXPORT_HELPER"

echo "distrobox-setup: helper installed at $EXPORT_HELPER"
