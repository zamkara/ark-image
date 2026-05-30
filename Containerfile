# Signature: emFta2FyYQ==
ARG VARIANT=ark

# Final Image (ark linux)
FROM docker.io/archlinux:latest
ARG VARIANT

LABEL ostree.bootable="true"
LABEL containers.bootc="1"

COPY aur-packages/*.pkg.tar.zst /tmp/

# Determine kernel based on variant
RUN KERNEL="linux"; \
    if [[ "$VARIANT" == *"-zen"* ]]; then KERNEL="linux-zen"; fi; \
    if [[ "$VARIANT" == *"-lts"* ]]; then KERNEL="linux-lts"; fi; \
    if [[ "$VARIANT" == *"-hardened"* ]]; then KERNEL="linux-hardened"; fi; \
    pacman -Syu --noconfirm && \
    pacman -S --noconfirm \
    base $KERNEL linux-firmware networkmanager mkinitcpio zram-generator \
    gnome-shell gnome-control-center gnome-disk-utility gnome-keyring gnome-session gnome-settings-daemon gnome-text-editor nautilus xdg-desktop-portal-gnome xdg-user-dirs-gtk gnome-backgrounds gnome-console gnome-initial-setup gdm plymouth gnome-software flatpak \
    util-linux openssl grub efibootmgr dosfstools e2fsprogs xfsprogs ostree skopeo btrfs-progs podman composefs distrobox ibus iso-codes shadow sudo git && \
    mkdir -p /sysroot /ostree && \
    ln -s /sysroot/ostree/repo /ostree/repo && \
    ln -s /sysroot/ostree/deploy /ostree/deploy && \
    chmod u+s /usr/bin/newuidmap /usr/bin/newgidmap && \
    if [[ "$VARIANT" == *"-nvidia" ]]; then \
        if [ "$KERNEL" = "linux" ]; then \
            pacman -S --noconfirm nvidia-open nvidia-utils nvidia-settings; \
        else \
            pacman -S --noconfirm nvidia-open-dkms ${KERNEL}-headers dkms nvidia-utils nvidia-settings; \
        fi \
    fi && \
    pacman -U --noconfirm /tmp/*.pkg.tar.zst && \
    pacman -S --noconfirm alga morewaita-icon-theme ark-system-tweaks && \
    rm -f /tmp/*.pkg.tar.zst && \
    pacman -Scc --noconfirm

# Enable plymouth and ostree in mkinitcpio
RUN sed -i 's/^MODULES=.*/MODULES=(btrfs vfat ext4 xfs erofs overlay loop)/g' /etc/mkinitcpio.conf && \
    sed -i 's/^HOOKS=.*/HOOKS=(base systemd microcode modconf kms keyboard sd-vconsole block plymouth ostree filesystems fsck)/g' /etc/mkinitcpio.conf && \
    mkinitcpio -P && \
    KVER=$(ls -1 /usr/lib/modules | grep -v 'extramodules' | head -n 1) && \
    IMG=$(ls -1 /boot/initramfs-*.img | grep -v 'fallback' | head -n 1) && \
    cp $IMG /usr/lib/modules/$KVER/initramfs.img && \
    rm -rf /boot/* /var/lib/pacman/sync/* /var/log/* /tmp/* /usr/share/doc/* /usr/share/man/* /usr/share/info/*

# Enable critical system services
RUN systemctl enable gdm NetworkManager && \
    systemctl mask systemd-firstboot.service

# Ensure bootupd is executable
RUN chmod +x /usr/libexec/bootupd /usr/bin/bootupctl
