#!/bin/bash
# BLS sync untuk systemd-boot + OSTree
# Kernel/initramfs/BLS entries ditulis ke EFI System Partition (ESP),
# bukan ke /boot (btrfs) — systemd-boot cuma baca dari ESP.
set -euo pipefail

SYSROOT="${SYSROOT:-/sysroot}"
OSTREE_REPO="$SYSROOT/ostree/repo"
DEPLOY_BASE="$SYSROOT/ostree/deploy/default/deploy"

[ ! -d "$OSTREE_REPO" ] && exit 0
[ ! -d "$DEPLOY_BASE" ] && exit 0

# Cari EFI System Partition
ESP=""
for candidate in "/boot" "/efi" "/boot/efi"; do
    if mountpoint -q "$candidate" 2>/dev/null && df -T "$candidate" 2>/dev/null | grep -q vfat; then
        ESP="$candidate"
        break
    fi
done
if [ -z "$ESP" ]; then
    ESP_DEV=""
    if command -v blkid >/dev/null 2>&1 && blkid -L EFI-SYSTEM >/dev/null 2>&1; then
        ESP_DEV=$(blkid -L EFI-SYSTEM 2>/dev/null)
    fi
    if [ -z "$ESP_DEV" ] && command -v lsblk >/dev/null 2>&1; then
        ESP_DEV=$(lsblk -o NAME,FSTYPE,LABEL -rn 2>/dev/null | awk '$2 == "vfat" && $3 == "EFI-SYSTEM" {print "/dev/"$1}' | head -1)
    fi
    if [ -n "$ESP_DEV" ]; then
        ESP="/mnt/esp"
        mkdir -p "$ESP" 2>/dev/null
        mount "$ESP_DEV" "$ESP" 2>/dev/null || ESP=""
    fi
fi
[ -z "$ESP" ] && exit 0

# Mount /sysroot RW jika perlu
if ! touch "$SYSROOT/.ark-bls-check" 2>/dev/null; then
    mount -o remount,rw "$SYSROOT" 2>/dev/null || true
fi
rm -f "$SYSROOT/.ark-bls-check" 2>/dev/null || true

export OSTREE_SYSROOT="$OSTREE_REPO"

deployments=$(ostree admin --sysroot="$SYSROOT" status 2>/dev/null | grep -oP 'ostree/deploy/default/deploy/\K[^ ]+' | sort -u || true)

if [ -z "$deployments" ]; then
    deployments=$(ls -d "$DEPLOY_BASE"/*/ 2>/dev/null | xargs -n1 basename 2>/dev/null || true)
fi

if [ -z "$deployments" ]; then
    echo "bls-sync: No deployments found"
    exit 0
fi

mkdir -p "$ESP/loader/entries" "$ESP/ostree"

ROOT_UUID=$(findmnt -n -o UUID "$SYSROOT" 2>/dev/null || blkid -s UUID -o value "$(findmnt -n -o SOURCE "$SYSROOT" 2>/dev/null)" 2>/dev/null || echo "")

for deploy_id in $deployments; do
    deploy_id=$(echo "$deploy_id" | tr -d '\n\r ')
    [ -z "$deploy_id" ] && continue

    deploy_path="$DEPLOY_BASE/$deploy_id"

    modules_dir="$deploy_path/usr/lib/modules"
    [ ! -d "$modules_dir" ] && continue

    kver=$(ls "$modules_dir" 2>/dev/null | grep -v 'extramodules' | head -1)
    [ -z "$kver" ] && continue
    [ ! -f "$modules_dir/$kver/vmlinuz" ] && continue

    vmlinuz_src="$modules_dir/$kver/vmlinuz"
    vmlinuz_dst="$ESP/ostree/$deploy_id/vmlinuz-$kver"

    initramfs_src=""
    for candidate in \
        "$modules_dir/$kver/initramfs.img" \
        "$deploy_path/boot/initramfs-$kver.img" \
        "$deploy_path/boot/initramfs-linux.img" \
        "$deploy_path/boot/initramfs-$kver-fallback.img"; do
        [ -f "$candidate" ] && initramfs_src="$candidate" && break
    done

    initramfs_dst="$ESP/ostree/$deploy_id/initramfs-$kver.img"

    mkdir -p "$ESP/ostree/$deploy_id"

    if [ ! -f "$vmlinuz_dst" ] || [ "$vmlinuz_src" -nt "$vmlinuz_dst" ]; then
        cp -f "$vmlinuz_src" "$vmlinuz_dst"
    fi

    if [ -f "$initramfs_src" ]; then
        if [ ! -f "$initramfs_dst" ] || [ "$initramfs_src" -nt "$initramfs_dst" ]; then
            cp -f "$initramfs_src" "$initramfs_dst"
        fi
    else
        if command -v dracut >/dev/null 2>&1; then
            dracut --force --no-hostonly --kver "$kver" \
                --kernel-image "$vmlinuz_dst" \
                "$initramfs_dst" 2>/dev/null || true
        elif command -v mkinitcpio >/dev/null 2>&1; then
            if [ -f "$deploy_path/etc/mkinitcpio.conf" ]; then
                cp "$deploy_path/etc/mkinitcpio.conf" /etc/mkinitcpio.conf.bls-tmp 2>/dev/null || true
            fi
            cp "$vmlinuz_src" "/boot/vmlinuz-$kver" 2>/dev/null || true
            mkinitcpio -k "$kver" -g "$initramfs_dst" 2>/dev/null || true
            rm -f "/boot/vmlinuz-$kver" 2>/dev/null || true
        fi
    fi

    [ ! -f "$initramfs_dst" ] && continue

    ostree_param="ostree=/ostree/boot.0/default/$deploy_id"
    if [ -f "$deploy_path/etc/os-release" ]; then
        title=$(grep -oP '(?<=^PRETTY_NAME=).*' "$deploy_path/etc/os-release" 2>/dev/null | tr -d '"' || echo "Ark Linux")
    else
        title="Ark Linux"
    fi

    cmdline=""
    for cmdline_file in "$deploy_path/usr/lib/ostree-boot/cmdline" "$deploy_path/etc/kernel/cmdline"; do
        if [ -f "$cmdline_file" ]; then
            cmdline=$(tr '\n' ' ' < "$cmdline_file")
            break
        fi
    done
    if [ -z "$cmdline" ]; then
        cmdline="root=UUID=$ROOT_UUID rw quiet splash loglevel=3 rd.udev.log_priority=3"
    fi
    cmdline="$cmdline $ostree_param"

    entry_file="$ESP/loader/entries/ostree-$deploy_id.conf"
    cat > "$entry_file" <<BLSENTRY
## This is a boot loader entry for ostree based on Ark Linux
title $title ($(date +%Y-%m-%d %H:%M))
version $kver
options $cmdline
linux /ostree/$deploy_id/vmlinuz-$kver
initrd /ostree/$deploy_id/initramfs-$kver.img
BLSENTRY

    echo "bls-sync: Generated entry for deployment $deploy_id (kernel $kver)"
done

for entry in "$ESP/loader/entries/ostree-"*.conf; do
    [ ! -f "$entry" ] && continue
    id=$(basename "$entry" .conf | sed 's/^ostree-//')
    found=0
    for d in $deployments; do
        d=$(echo "$d" | tr -d '\n\r ')
        [ "$id" = "$d" ] && found=1 && break
    done
    if [ "$found" = "0" ]; then
        echo "bls-sync: Removing stale entry $id"
        rm -f "$entry"
        rm -rf "$ESP/ostree/$id" 2>/dev/null || true
    fi
done

if [ ! -f "$ESP/loader/loader.conf" ]; then
    cat > "$ESP/loader/loader.conf" <<LOADER
timeout 3
console-mode max
default @
LOADER
fi

mount -o remount,ro "$SYSROOT" 2>/dev/null || true
