#!/bin/bash
# Injected into each distrobox container via --post-init-hooks.
# Installs package manager hooks that auto-export new .desktop apps to the host.

REAL_USER=$(getent passwd 1000 | cut -d: -f1)
EXPORT_COMMANDS_FILE="/tmp/ark-export-commands"

# --- apt (Debian/Ubuntu) — follows VSO pattern 1:1 ---
install_apt_hooks() {
    mkdir -p /usr/share/ark/hooks /etc/apt/apt.conf.d

    cat > /usr/share/ark/hooks/apt-pre << 'EOF'
#!/bin/bash
apt-mark showmanual > /tmp/ark-manually-installed-packages-before
EOF

    cat > /usr/share/ark/hooks/apt-post << HOOK
#!/bin/bash
if [ -z \$SUDO_UID ]; then exit 0; fi
apt-mark showmanual > /tmp/ark-manually-installed-packages-after
installed_apps="\$(grep -v -f /tmp/ark-manually-installed-packages-before /tmp/ark-manually-installed-packages-after)"
truncate -s 0 "$EXPORT_COMMANDS_FILE"
while IFS= read -r app; do
    [[ "x\$app" == "x" ]] && continue
    echo "trying to export \$app"
    echo "distrobox-export --app \$app" >> "$EXPORT_COMMANDS_FILE"
done <<< "\$installed_apps"
if [ -s "$EXPORT_COMMANDS_FILE" ]; then
    systemd-run --user --machine="\${SUDO_UID}@.host" /usr/bin/host-spawn bash "$EXPORT_COMMANDS_FILE" &>/dev/null
fi
HOOK

    chmod +x /usr/share/ark/hooks/apt-pre /usr/share/ark/hooks/apt-post
    printf 'DPkg::Pre-Install-Pkgs {"/usr/share/ark/hooks/apt-pre"};\n' > /etc/apt/apt.conf.d/99-ark-pre
    printf 'Dpkg::Tools::Options::/usr/share/ark/hooks/apt-pre::Version "2";\n' >> /etc/apt/apt.conf.d/99-ark-pre
    printf 'DPkg::Post-Invoke {"/usr/share/ark/hooks/apt-post"};\n' > /etc/apt/apt.conf.d/99-ark-post
}

# --- pacman (Arch Linux) — same pattern, alpm hooks ---
install_pacman_hooks() {
    mkdir -p /usr/share/ark/hooks /etc/pacman.d/hooks

    cat > /usr/share/ark/hooks/pacman-pre << 'EOF'
#!/bin/bash
pacman -Qqe > /tmp/ark-manually-installed-packages-before
EOF

    cat > /usr/share/ark/hooks/pacman-post << HOOK
#!/bin/bash
pacman -Qqe > /tmp/ark-manually-installed-packages-after
if [ ! -f /tmp/ark-manually-installed-packages-before ]; then exit 0; fi
installed_apps="\$(grep -v -f /tmp/ark-manually-installed-packages-before /tmp/ark-manually-installed-packages-after 2>/dev/null)"
truncate -s 0 "$EXPORT_COMMANDS_FILE"
while IFS= read -r app; do
    [[ "x\$app" == "x" ]] && continue
    echo "trying to export \$app"
    echo "distrobox-export --app \$app" >> "$EXPORT_COMMANDS_FILE"
done <<< "\$installed_apps"
if [ -s "$EXPORT_COMMANDS_FILE" ]; then
    runuser -u $REAL_USER -- bash "$EXPORT_COMMANDS_FILE" &>/dev/null
fi
HOOK

    chmod +x /usr/share/ark/hooks/pacman-pre /usr/share/ark/hooks/pacman-post

    cat > /etc/pacman.d/hooks/ark-pre.hook << 'EOF'
[Trigger]
Operation = Install
Operation = Upgrade
Type = Package
Target = *

[Action]
When = PreTransaction
Exec = /usr/share/ark/hooks/pacman-pre
EOF

    cat > /etc/pacman.d/hooks/ark-post.hook << 'EOF'
[Trigger]
Operation = Install
Operation = Upgrade
Type = Package
Target = *

[Action]
When = PostTransaction
Exec = /usr/share/ark/hooks/pacman-post
EOF
}

# --- dnf (Fedora) — same pattern, dnf plugin ---
install_dnf_hooks() {
    mkdir -p /usr/share/ark/hooks /etc/dnf/plugins

    cat > /usr/share/ark/hooks/dnf-pre << 'EOF'
#!/bin/bash
dnf repoquery --userinstalled --qf '%{name}' 2>/dev/null > /tmp/ark-manually-installed-packages-before
EOF

    cat > /usr/share/ark/hooks/dnf-post << HOOK
#!/bin/bash
dnf repoquery --userinstalled --qf '%{name}' 2>/dev/null > /tmp/ark-manually-installed-packages-after
if [ ! -f /tmp/ark-manually-installed-packages-before ]; then exit 0; fi
installed_apps="\$(grep -v -f /tmp/ark-manually-installed-packages-before /tmp/ark-manually-installed-packages-after 2>/dev/null)"
truncate -s 0 "$EXPORT_COMMANDS_FILE"
while IFS= read -r app; do
    [[ "x\$app" == "x" ]] && continue
    echo "trying to export \$app"
    echo "distrobox-export --app \$app" >> "$EXPORT_COMMANDS_FILE"
done <<< "\$installed_apps"
if [ -s "$EXPORT_COMMANDS_FILE" ]; then
    runuser -u $REAL_USER -- bash "$EXPORT_COMMANDS_FILE" &>/dev/null
fi
HOOK

    chmod +x /usr/share/ark/hooks/dnf-pre /usr/share/ark/hooks/dnf-post

    cat > /etc/dnf/plugins/ark-export.conf << 'EOF'
[main]
enabled=1
EOF

    cat > /etc/dnf/plugins/ark-export.py << 'PYEOF'
from dnf.plugin import Plugin
import subprocess
PLUGIN_CONF = 'ark-export'
class ArkExport(Plugin):
    name = 'ark-export'
    def pre_transaction(self, transaction):
        subprocess.run(['/usr/share/ark/hooks/dnf-pre'], check=False)
    def post_transaction(self, transaction):
        if any(p.action in (0, 1) for p in transaction):
            subprocess.run(['/usr/share/ark/hooks/dnf-post'], check=False)
PYEOF
}

# --- zypper (openSUSE) — same pattern, zypper plugin ---
install_zypper_hooks() {
    mkdir -p /usr/share/ark/hooks /etc/zypp/plugins/commit

    cat > /usr/share/ark/hooks/zypper-pre << 'EOF'
#!/bin/bash
zypper search --installed-only --type package -s 2>/dev/null | awk 'NR>2 && /^i/{print $3}' > /tmp/ark-manually-installed-packages-before
EOF

    cat > /usr/share/ark/hooks/zypper-post << HOOK
#!/bin/bash
zypper search --installed-only --type package -s 2>/dev/null | awk 'NR>2 && /^i/{print $3}' > /tmp/ark-manually-installed-packages-after
if [ ! -f /tmp/ark-manually-installed-packages-before ]; then exit 0; fi
installed_apps="\$(grep -v -f /tmp/ark-manually-installed-packages-before /tmp/ark-manually-installed-packages-after 2>/dev/null)"
truncate -s 0 "$EXPORT_COMMANDS_FILE"
while IFS= read -r app; do
    [[ "x\$app" == "x" ]] && continue
    echo "trying to export \$app"
    echo "distrobox-export --app \$app" >> "$EXPORT_COMMANDS_FILE"
done <<< "\$installed_apps"
if [ -s "$EXPORT_COMMANDS_FILE" ]; then
    runuser -u $REAL_USER -- bash "$EXPORT_COMMANDS_FILE" &>/dev/null
fi
HOOK

    chmod +x /usr/share/ark/hooks/zypper-pre /usr/share/ark/hooks/zypper-post

    cat > /etc/zypp/plugins/commit/ark-export << PLUGIN
#!/usr/bin/env python3
import sys, subprocess
def ack(): print("_ZYPPERARG_ACK\n"); sys.stdout.flush()
for line in sys.stdin:
    line = line.strip()
    if line == "PLUGINBEGIN": ack()
    elif line == "COMMITBEGIN": subprocess.run(['/usr/share/ark/hooks/zypper-pre']); ack()
    elif line == "COMMITEND": subprocess.run(['/usr/share/ark/hooks/zypper-post']); ack()
    elif line == "PLUGINEND": ack(); break
PLUGIN
    chmod +x /etc/zypp/plugins/commit/ark-export
}

# --- apk (Alpine) — same pattern, apk commit hooks ---
install_apk_hooks() {
    mkdir -p /usr/share/ark/hooks /etc/apk/commit_hooks.d

    cat > /usr/share/ark/hooks/apk-post << HOOK
#!/bin/bash
apk info 2>/dev/null | sort > /tmp/ark-manually-installed-packages-after
if [ ! -f /tmp/ark-manually-installed-packages-before ]; then
    cp /tmp/ark-manually-installed-packages-after /tmp/ark-manually-installed-packages-before
    exit 0
fi
installed_apps="\$(grep -v -f /tmp/ark-manually-installed-packages-before /tmp/ark-manually-installed-packages-after 2>/dev/null)"
truncate -s 0 "$EXPORT_COMMANDS_FILE"
while IFS= read -r app; do
    [[ "x\$app" == "x" ]] && continue
    echo "trying to export \$app"
    echo "distrobox-export --app \$app" >> "$EXPORT_COMMANDS_FILE"
done <<< "\$installed_apps"
if [ -s "$EXPORT_COMMANDS_FILE" ]; then
    runuser -u $REAL_USER -- bash "$EXPORT_COMMANDS_FILE" &>/dev/null
fi
cp /tmp/ark-manually-installed-packages-after /tmp/ark-manually-installed-packages-before
HOOK

    chmod +x /usr/share/ark/hooks/apk-post
    ln -sf /usr/share/ark/hooks/apk-post /etc/apk/commit_hooks.d/ark-export
}

# --- xbps (Void Linux) — same pattern, xbps hooks ---
install_xbps_hooks() {
    mkdir -p /usr/share/ark/hooks /etc/xbps.d

    cat > /usr/share/ark/hooks/xbps-post << HOOK
#!/bin/bash
xbps-query -l 2>/dev/null | awk '{print \$2}' | sort > /tmp/ark-manually-installed-packages-after
if [ ! -f /tmp/ark-manually-installed-packages-before ]; then
    cp /tmp/ark-manually-installed-packages-after /tmp/ark-manually-installed-packages-before
    exit 0
fi
installed_apps="\$(grep -v -f /tmp/ark-manually-installed-packages-before /tmp/ark-manually-installed-packages-after 2>/dev/null)"
truncate -s 0 "$EXPORT_COMMANDS_FILE"
while IFS= read -r app; do
    [[ "x\$app" == "x" ]] && continue
    pkg="\$(echo "\$app" | sed 's/-[0-9].*//')"
    echo "trying to export \$pkg"
    echo "distrobox-export --app \$pkg" >> "$EXPORT_COMMANDS_FILE"
done <<< "\$installed_apps"
if [ -s "$EXPORT_COMMANDS_FILE" ]; then
    runuser -u $REAL_USER -- bash "$EXPORT_COMMANDS_FILE" &>/dev/null
fi
cp /tmp/ark-manually-installed-packages-after /tmp/ark-manually-installed-packages-before
HOOK

    chmod +x /usr/share/ark/hooks/xbps-post

    mv /usr/bin/xbps-install /usr/bin/xbps-install.real 2>/dev/null || true
    cat > /usr/bin/xbps-install << 'WRAPPER'
#!/bin/bash
xbps-query -l 2>/dev/null | awk '{print $2}' | sort > /tmp/ark-manually-installed-packages-before
/usr/bin/xbps-install.real "$@"
ret=$?
/usr/share/ark/hooks/xbps-post
exit $ret
WRAPPER
    chmod +x /usr/bin/xbps-install
}

# --- nix (NixOS) — same pattern, nix profile hooks ---
install_nix_hooks() {
    mkdir -p /usr/share/ark/hooks

    cat > /usr/share/ark/hooks/nix-post << HOOK
#!/bin/bash
nix-env -q 2>/dev/null | sort > /tmp/ark-manually-installed-packages-after
if [ ! -f /tmp/ark-manually-installed-packages-before ]; then
    cp /tmp/ark-manually-installed-packages-after /tmp/ark-manually-installed-packages-before
    exit 0
fi
installed_apps="\$(grep -v -f /tmp/ark-manually-installed-packages-before /tmp/ark-manually-installed-packages-after 2>/dev/null)"
truncate -s 0 "$EXPORT_COMMANDS_FILE"
while IFS= read -r app; do
    [[ "x\$app" == "x" ]] && continue
    pkg="\$(echo "\$app" | sed 's/-[0-9].*//')"
    echo "trying to export \$pkg"
    echo "distrobox-export --app \$pkg" >> "$EXPORT_COMMANDS_FILE"
done <<< "\$installed_apps"
if [ -s "$EXPORT_COMMANDS_FILE" ]; then
    runuser -u $REAL_USER -- bash "$EXPORT_COMMANDS_FILE" &>/dev/null
fi
cp /tmp/ark-manually-installed-packages-after /tmp/ark-manually-installed-packages-before
HOOK

    chmod +x /usr/share/ark/hooks/nix-post

    # Wrap nix-env to snapshot before and export after
    mv /usr/bin/nix-env /usr/bin/nix-env.real 2>/dev/null || true
    cat > /usr/bin/nix-env << 'WRAPPER'
#!/bin/bash
nix-env -q 2>/dev/null | sort > /tmp/ark-manually-installed-packages-before
/usr/bin/nix-env.real "$@"
ret=$?
/usr/share/ark/hooks/nix-post
exit $ret
WRAPPER
    chmod +x /usr/bin/nix-env

    # Same for nix profile install
    mv /usr/bin/nix /usr/bin/nix.real 2>/dev/null || true
    cat > /usr/bin/nix << 'WRAPPER'
#!/bin/bash
nix-env -q 2>/dev/null | sort > /tmp/ark-manually-installed-packages-before
/usr/bin/nix.real "$@"
ret=$?
/usr/share/ark/hooks/nix-post
exit $ret
WRAPPER
    chmod +x /usr/bin/nix
}

if command -v apt-get &>/dev/null; then
    install_apt_hooks
elif command -v pacman &>/dev/null; then
    install_pacman_hooks
elif command -v dnf &>/dev/null; then
    install_dnf_hooks
elif command -v zypper &>/dev/null; then
    install_zypper_hooks
elif command -v apk &>/dev/null; then
    install_apk_hooks
elif command -v nix-env &>/dev/null; then
    install_nix_hooks
elif command -v xbps-install &>/dev/null; then
    install_xbps_hooks
fi
