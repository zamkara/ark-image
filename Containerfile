# Signature: emFta2FyYQ==
ARG VARIANT=ark

# Final Image (ark linux)
FROM docker.io/archlinux:latest
ARG VARIANT

LABEL ostree.bootable="true"
LABEL containers.bootc="1"

COPY aur-packages/*.pkg.tar.zst /tmp/

# Determine kernel based on variant
RUN set -e; \
    KERNEL="linux"; \
    if [[ "$VARIANT" == *"-zen"* ]]; then KERNEL="linux-zen"; fi; \
    if [[ "$VARIANT" == *"-lts"* ]]; then KERNEL="linux-lts"; fi; \
    if [[ "$VARIANT" == *"-hardened"* ]]; then KERNEL="linux-hardened"; fi; \
    pacman -Syu --noconfirm; \
    pacman -S --noconfirm \
    base $KERNEL linux-firmware networkmanager mkinitcpio zram-generator \
    gnome-shell gnome-control-center gnome-disk-utility gnome-keyring gnome-session gnome-settings-daemon nautilus xdg-desktop-portal-gnome xdg-user-dirs-gtk gnome-backgrounds ptyxis gdm plymouth gnome-software flatpak gnome-initial-setup \
    util-linux openssl efibootmgr dosfstools e2fsprogs xfsprogs ostree skopeo btrfs-progs podman composefs distrobox ibus iso-codes shadow sudo git; \
    if [[ "$VARIANT" == *"-nvidia" ]]; then \
        if [ "$KERNEL" = "linux" ]; then \
            pacman -S --noconfirm nvidia-open nvidia-utils nvidia-settings; \
        else \
            pacman -S --noconfirm nvidia-open-dkms ${KERNEL}-headers dkms nvidia-utils nvidia-settings; \
        fi; \
    fi; \
    pacman -U --noconfirm /tmp/*.pkg.tar.zst; \
    sed -i 's/^#\(.*UTF-8.*\)/\1/' /etc/locale.gen; \
    sed -i '/@/s/^/#/' /etc/locale.gen; \
    locale-gen; \
    echo "LANG=en_US.UTF-8" > /etc/locale.conf; \
    ln -sf /usr/share/zoneinfo/UTC /etc/localtime; \
    chmod u+s /usr/bin/newuidmap /usr/bin/newgidmap; \
    rm -f /tmp/*.pkg.tar.zst; \
    rm -f /usr/share/applications/{bssh,bvnc,avahi-discover,qv4l2,qvidcap,stoken-gui,stoken-gui-small,org.gnome.Extensions,org.gnome.TextEditor,lstopo,hwloc-ls,org.gnome.Logs,org.gnome.Console,ibus,ibus-setup,ibus-wayland,nvidia-settings}.desktop 2>/dev/null || true; \
    sed -i 's/^Name=.*/Name=Terminal/' /usr/share/applications/org.gnome.Ptyxis.desktop 2>/dev/null || true; \
    pacman -Scc --noconfirm

# Enable plymouth and ostree in mkinitcpio
RUN sed -i 's/^MODULES=.*/MODULES=(btrfs vfat ext4 xfs erofs overlay loop)/g' /etc/mkinitcpio.conf && \
    sed -i 's/^HOOKS=.*/HOOKS=(base systemd microcode modconf kms keyboard sd-vconsole block plymouth ostree filesystems fsck)/g' /etc/mkinitcpio.conf && \
    mkinitcpio -P && \
    KVER=$(ls -1 /usr/lib/modules | grep -v 'extramodules' | head -n 1) && \
    IMG=$(ls -1 /boot/initramfs-*.img | grep -v 'fallback' | head -n 1) && \
    cp $IMG /usr/lib/modules/$KVER/initramfs.img && \
    rm -rf /boot/* /var/lib/pacman/sync/* /var/log/* /tmp/* /usr/share/doc/* /usr/share/man/* /usr/share/info/*

# Enable critical system services and setup ostree sysroot structure
RUN systemctl enable gdm NetworkManager && \
    systemctl mask systemd-firstboot.service && \
    mkdir -p /etc/ostree && \
    printf "[sysroot]\ncomposefs=false\n" > /etc/ostree/prepare-root.conf && \
    mkdir -p /sysroot && \
    mkdir -p /sysroot/ostree && \
    ln -sfn sysroot/ostree /ostree && \
    glib-compile-schemas /usr/share/glib-2.0/schemas/

# Ensure bootupd is executable
RUN chmod +x /usr/libexec/bootupd /usr/bin/bootupctl
