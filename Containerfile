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
    sed -i '/NoExtract/d' /etc/pacman.conf; \
    KERNEL="linux"; \
    if [[ "$VARIANT" == *"-zen"* ]]; then KERNEL="linux-zen"; fi; \
    if [[ "$VARIANT" == *"-lts"* ]]; then KERNEL="linux-lts"; fi; \
    if [[ "$VARIANT" == *"-hardened"* ]]; then KERNEL="linux-hardened"; fi; \
    pacman -Syu --noconfirm; \
    pacman -S --noconfirm \
    base glibc $KERNEL linux-firmware networkmanager mkinitcpio zram-generator \
    gnome-shell gnome-control-center gnome-disk-utility gnome-keyring gnome-session gnome-settings-daemon nautilus xdg-desktop-portal-gnome xdg-user-dirs-gtk gnome-backgrounds gnome-console gdm plymouth gnome-software flatpak gnome-initial-setup \
    webp-pixbuf-loader libheif libavif libraw ffmpegthumbnailer poppler-glib libgsf \
    util-linux openssl efibootmgr dosfstools e2fsprogs xfsprogs ostree skopeo btrfs-progs podman composefs distrobox ibus iso-codes shadow sudo git nano fastfetch zsh fish starship github-cli base-devel nix scrcpy android-tools; \
    if [[ "$VARIANT" == *"-nvidia" ]]; then \
        if [ "$KERNEL" = "linux" ]; then \
            pacman -S --noconfirm nvidia-open nvidia-utils nvidia-settings; \
        else \
            pacman -S --noconfirm nvidia-open-dkms ${KERNEL}-headers dkms nvidia-utils nvidia-settings; \
        fi; \
    fi; \
    pacman -U --noconfirm /tmp/*.pkg.tar.zst; \
    sed -i 's/^#\(.*UTF-8.*\)/\1/' /etc/locale.gen; \
    locale-gen; \
    echo "LANG=en_US.UTF-8" > /etc/locale.conf; \
    ln -sf /usr/share/zoneinfo/UTC /etc/localtime; \
    chmod u+s /usr/bin/newuidmap /usr/bin/newgidmap; \
    rm -f /tmp/*.pkg.tar.zst; \
    rm -f /usr/share/applications/{bssh,bvnc,avahi-discover,qv4l2,qvidcap,stoken-gui,stoken-gui-small,org.gnome.Extensions,org.gnome.TextEditor,lstopo,hwloc-ls,org.gnome.Logs,ibus,ibus-setup,ibus-wayland}.desktop 2>/dev/null || true; \
    pacman -Scc --noconfirm

# Pre-pull archlinux container for instant distrobox readiness on first boot
# Note: use VFS storage driver because CI runs inside a container where overlayfs is nested
RUN mkdir -p /etc/containers && \
    printf '[storage]\ndriver = "vfs"\n' > /etc/containers/storage.conf && \
    podman pull docker.io/archlinux:latest

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

# Setup Nix package manager for persistent usage across OSTree upgrades
# /nix/store stays in the immutable image; /nix/var/nix is symlinked to /var/nix for persistence
RUN set -e; \
    mkdir -p /var/nix; \
    rm -rf /nix/var/nix; \
    ln -sf /var/nix /nix/var/nix; \
    systemd-sysusers; \
    systemd-tmpfiles --create; \
    echo "experimental-features = nix-command flakes" >> /etc/nix/nix.conf; \
    echo "trusted-users = root @wheel" >> /etc/nix/nix.conf; \
    echo "extra-nix-path = nixpkgs=channel:nixpkgs-unstable" >> /etc/nix/nix.conf; \
    systemctl enable nix-daemon.socket nix-daemon.service

# Remove pacman — useless on immutable host
RUN rm -rf \
    /usr/bin/pacman* \
    /usr/bin/makepkg* \
    /usr/bin/repo-add \
    /usr/bin/repo-elephant \
    /usr/bin/repo-remove \
    /usr/bin/testpkg \
    /usr/bin/vercmp \
    /usr/lib/libalpm.so* \
    /usr/include/alpm* \
    /usr/lib/pkgconfig/libalpm.pc \
    /usr/lib/sysusers.d/alpm.conf \
    /usr/lib/systemd/system/sockets.target.wants/dirmngr@etc-pacman.d-gnupg.socket \
    /usr/lib/systemd/system/sockets.target.wants/gpg-agent*@etc-pacman.d-gnupg.socket \
    /usr/lib/systemd/system/sockets.target.wants/keyboxd@etc-pacman.d-gnupg.socket \
    /usr/share/bash-completion/completions/pacman* \
    /usr/share/bash-completion/completions/makepkg* \
    /usr/share/zsh/site-functions/_pacman* \
    /usr/share/man/man8/pacman* \
    /usr/share/man/man8/makepkg* \
    /usr/share/man/man8/repo-* \
    /usr/share/man/man8/vercmp* \
    /usr/share/man/man8/testpkg* \
    /etc/pacman.conf \
    /etc/pacman.d/ \
    /var/lib/pacman/

# BLS sync script — generates BLS entries + copies kernel/initrd to /boot per-deployment
COPY bls-sync.sh /usr/libexec/ark/bls-sync.sh
RUN chmod +x /usr/libexec/ark/bls-sync.sh

# Drop-in: run BLS sync after finalization for both OSTree and bootc services
COPY bls-sync.conf /usr/lib/systemd/system/ostree-finalize-staged.service.d/bls-sync.conf
COPY bls-sync.conf /usr/lib/systemd/system/bootc-finalize-staged.service.d/bls-sync.conf

# Pacman handler — catch accidental pacman calls on immutable host
COPY pacman.sh /usr/local/bin/pacman
RUN chmod +x /usr/local/bin/pacman
