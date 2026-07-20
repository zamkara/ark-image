#!/bin/bash
# Auto-apply MoreWaita folder icons to home directories.
# Dynamically discovers matching icons — no hardcoded list needed.
# Runs at every GNOME login (idempotent via gio set xattr).

[ -n "$HOME" ] && [ -d "$HOME" ] || exit 0

ICON_DIR="/usr/share/icons/MoreWaita/scalable/places"
[ -d "$ICON_DIR" ] || exit 0

for dir in "$HOME"/*/; do
    [ -d "$dir" ] || continue
    name=$(basename "$dir")
    # skip hidden dirs
    case "$name" in .*) continue ;; esac

    icon="folder-${name,,}"
    [ -f "$ICON_DIR/$icon.svg" ] || continue

    current=$(gio info --attributes=metadata::custom-icon-name "$dir" 2>/dev/null \
              | awk -F': ' '/metadata::custom-icon-name/ {print $2}')
    [ "$current" = "$icon" ] && continue

    gio set "$dir" metadata::custom-icon-name "$icon" 2>/dev/null
done
