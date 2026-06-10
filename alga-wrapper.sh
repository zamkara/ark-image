#!/bin/bash
ALGA_UPDATED="/var/lib/alga/bin/alga"
if [ -x "$ALGA_UPDATED" ]; then
    exec "$ALGA_UPDATED" "$@"
fi
exec /usr/bin/alga "$@"
