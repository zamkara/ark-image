#!/bin/bash
NEW_HOSTNAME=$(hostname)
for uid_dir in /run/user/*/; do
    uid=$(basename "$uid_dir")
    user=$(getent passwd "$uid" | cut -d: -f1)
    [ -z "$user" ] && continue
    runuser -u "$user" -- sh -c '
        podman ps --format "{{.Names}}" 2>/dev/null | while read -r name; do
            podman exec "$name" hostname "'"$NEW_HOSTNAME"'" 2>/dev/null || true
        done
    '
done
