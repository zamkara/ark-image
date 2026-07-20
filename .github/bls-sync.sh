#!/bin/bash
set -euo pipefail

SYSROOT="${SYSROOT:-/sysroot}"
OSTREE_REPO="$SYSROOT/ostree/repo"
DEPLOY_BASE="$SYSROOT/ostree/deploy/default/deploy"

[ ! -d "$OSTREE_REPO" ] && exit 0
[ ! -d "$DEPLOY_BASE" ] && exit 0

ESP="${ESP:-}"
if [ -z "$ESP" ]; then
    # Cari EFI System Partition
    for candidate in "/boot" "/efi" "/boot/efi"; do
        if mountpoint -q "$candidate" 2>/dev/null && df -T "$candidate" 2>/dev/null | grep -q vfat; then
            ESP="$candidate"
            break
        fi
    done
fi
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

# Remove auto-generated bootc/ostree dirs (format: default-<hash>) — these are written
# by 'bootc install' and never cleaned up; they waste ESP space.
for _rmdir in "$ESP/ostree/default-"*/; do
    [ -d "$_rmdir" ] || continue
    echo "bls-sync: Removing auto-generated dir $(basename "$_rmdir")"
    rm -rf "$_rmdir" 2>/dev/null || true
done

# Prune ESP: keep only the 2 most recent deployment dirs to prevent ESP from filling up.
_esp_n=0
for _esp_pd in $(ls -dt "$ESP/ostree"/[0-9a-f]*.?/ 2>/dev/null); do
    _esp_n=$((_esp_n + 1))
    if [ "$_esp_n" -le 2 ]; then continue; fi
    _esp_pi=$(basename "$_esp_pd")
    echo "bls-sync: Pruning old ESP deployment: $_esp_pi"
    rm -f "$ESP/loader/entries/ostree-$_esp_pi.conf" 2>/dev/null || true
    rm -rf "$_esp_pd" 2>/dev/null || true
done

# Mount /sysroot RW jika perlu — coba via device agar tidak gagal pada bind mount
if ! touch "$SYSROOT/.ark-bls-check" 2>/dev/null; then
    SYSROOT_DEV=$(findmnt -n -o SOURCE "$SYSROOT" 2>/dev/null || true)
    if [ -n "$SYSROOT_DEV" ]; then
        mount -o remount,rw "$SYSROOT_DEV" "$SYSROOT" 2>/dev/null || \
        mount -o remount,rw "$SYSROOT" 2>/dev/null || true
    else
        mount -o remount,rw "$SYSROOT" 2>/dev/null || true
    fi
fi
rm -f "$SYSROOT/.ark-bls-check" 2>/dev/null || true

export OSTREE_SYSROOT="$OSTREE_REPO"

deployments=$(ls -d "$DEPLOY_BASE"/*/ 2>/dev/null | xargs -n1 basename 2>/dev/null || true)

if [ -z "$deployments" ]; then
    deployments=$(ostree admin --sysroot="$SYSROOT" status 2>/dev/null | grep -oP 'ostree/deploy/default/deploy/\K[^ ]+' || true)
fi

if [ -z "$deployments" ]; then
    echo "bls-sync: No deployments found"
    exit 0
fi

# Also include any staged deployment that hasn't been finalized yet.
# bootc upgrade stages to $DEPLOY_BASE but marks it pending — ensure we create
# an ESP entry for it so the next boot menu already shows 2 entries.
staged_file="$SYSROOT/ostree/deploy/default/staged-deployment"
if [ -f "$staged_file" ]; then
    staged_id=$(grep -oP '"checksum"\s*:\s*"\K[a-f0-9]+' "$staged_file" 2>/dev/null | head -1 || true)
    staged_serial=$(grep -oP '"deployserial"\s*:\s*\K[0-9]+' "$staged_file" 2>/dev/null | head -1 || true)
    if [ -n "$staged_id" ]; then
        staged_serial="${staged_serial:-0}"
        full_staged="${staged_id}.${staged_serial}"
        if [ -d "$DEPLOY_BASE/$full_staged" ] && ! printf '%s' "$deployments" | grep -qF "$full_staged"; then
            deployments="$deployments
$full_staged"
            echo "bls-sync: Including staged deployment $full_staged"
        fi
    fi
fi

echo "bls-sync: Known deployments: $(printf '%s' "$deployments" | tr '\n' ' ')"

mkdir -p "$ESP/loader/entries" "$ESP/ostree"

# Detect /boot mount (may differ from ESP when /boot is on btrfs root)
BOOT_DIR=""
for candidate in "/boot"; do
    if mountpoint -q "$candidate" 2>/dev/null; then
        BOOT_FSTYPE=$(df -T "$candidate" 2>/dev/null | awk 'NR==2{print $2}')
        if [ "$BOOT_FSTYPE" != "vfat" ]; then
            BOOT_DIR="$candidate"
        fi
        break
    fi
done

ROOT_UUID=$(findmnt -n -o UUID "$SYSROOT" 2>/dev/null || blkid -s UUID -o value "$(findmnt -n -o SOURCE "$SYSROOT" 2>/dev/null)" 2>/dev/null || echo "")
ROOT_SUBVOL=$(findmnt -n -o OPTIONS "$SYSROOT" 2>/dev/null | tr ',' '\n' | grep '^subvol=' | head -1 | sed 's|^subvol=||;s|^/||' || true)

# Detect LUKS-encrypted root
LUKS_UUID=""
_root_source=$(findmnt -n -o SOURCE "$SYSROOT" 2>/dev/null || true)
if echo "$_root_source" | grep -q "^/dev/mapper/"; then
    _luks_name="${_root_source%%\[*}"
    _luks_name="${_luks_name##*/}"
    _luks_backing=$(cryptsetup status "$_luks_name" 2>/dev/null | awk '/device:/ {print $2}' || true)
    if [ -n "$_luks_backing" ]; then
        LUKS_UUID=$(blkid -s UUID -o value "$_luks_backing" 2>/dev/null || true)
    fi
fi

count=0
for deploy_id in $deployments; do
    deploy_id=$(echo "$deploy_id" | tr -d '\n\r ')
    [ -z "$deploy_id" ] && continue
    count=$((count + 1))

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
        cp -f "$vmlinuz_src" "$vmlinuz_dst" || { echo "bls-sync: Failed to copy vmlinuz for $deploy_id, skipping"; continue; }
    fi

    if [ -f "$initramfs_src" ]; then
        if [ ! -f "$initramfs_dst" ] || [ "$initramfs_src" -nt "$initramfs_dst" ]; then
            cp -f "$initramfs_src" "$initramfs_dst" || { echo "bls-sync: Failed to copy initramfs for $deploy_id, skipping"; continue; }
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

    bootcsum="${deploy_id%.*}"
    bootserial="${deploy_id##*.}"
    boot_slot=""
    for slot in boot.0 boot.1; do
        if [ -L "$SYSROOT/ostree/$slot/default/$bootcsum/$bootserial" ] || \
           [ -d "$SYSROOT/ostree/$slot/default/$bootcsum/$bootserial" ]; then
            boot_slot="$slot"
            break
        fi
    done
    if [ -z "$boot_slot" ]; then
        boot_slot="boot.0"
        # Determine the next subversion for boot.0 (boot.0 -> boot.0.N)
        _boot0_target=$(readlink "$SYSROOT/ostree/boot.0" 2>/dev/null || true)
        if [ -n "$_boot0_target" ] && [ -d "$SYSROOT/ostree/$_boot0_target" ]; then
            bootlink_base="$SYSROOT/ostree/$_boot0_target"
        else
            # boot.0 is missing or is a plain dir — create proper symlink structure
            _boot0_ver=0
            while [ -d "$SYSROOT/ostree/boot.0.$_boot0_ver" ]; do
                _boot0_ver=$((_boot0_ver + 1))
            done
            bootlink_base="$SYSROOT/ostree/boot.0.$_boot0_ver"
            mkdir -p "$bootlink_base" 2>/dev/null || true
            # Migrate existing plain-dir boot.0 contents if present
            if [ -d "$SYSROOT/ostree/boot.0/default" ] && [ ! -L "$SYSROOT/ostree/boot.0" ]; then
                cp -a "$SYSROOT/ostree/boot.0/default" "$bootlink_base/" 2>/dev/null || true
                rm -rf "$SYSROOT/ostree/boot.0" 2>/dev/null || true
            else
                rm -rf "$SYSROOT/ostree/boot.0" 2>/dev/null || true
            fi
            ln -sfn "boot.0.$_boot0_ver" "$SYSROOT/ostree/boot.0" 2>/dev/null || true
        fi
        bootlink_dir="$bootlink_base/default/$bootcsum"
        mkdir -p "$bootlink_dir" 2>/dev/null || true
        ln -sfn "../../../deploy/default/deploy/$deploy_id" "$bootlink_dir/$bootserial" 2>/dev/null || true
    fi
    ostree_param="ostree=/ostree/$boot_slot/default/${bootcsum}/${bootserial}"
    deploy_date=$(date -r "$deploy_path" "+%Y%m%d%H%M%S" 2>/dev/null || date "+%Y%m%d%H%M%S")
    title="Arch Linux $deploy_date"

    cmdline=""
    for cmdline_file in "$deploy_path/usr/lib/ostree-boot/cmdline" "$deploy_path/etc/kernel/cmdline"; do
        if [ -f "$cmdline_file" ]; then
            cmdline=$(tr '\n' ' ' < "$cmdline_file")
            break
        fi
    done
    if [ -z "$cmdline" ]; then
        if [ -n "$LUKS_UUID" ]; then
            if [ -n "$ROOT_SUBVOL" ] && [ "$ROOT_SUBVOL" != "/" ]; then
                cmdline="rd.luks.name=$LUKS_UUID=ark-root root=/dev/mapper/ark-root rootflags=subvol=$ROOT_SUBVOL rw quiet splash loglevel=3 rd.udev.log_priority=3"
            else
                cmdline="rd.luks.name=$LUKS_UUID=ark-root root=/dev/mapper/ark-root rw quiet splash loglevel=3 rd.udev.log_priority=3"
            fi
        elif [ -n "$ROOT_SUBVOL" ] && [ "$ROOT_SUBVOL" != "/" ]; then
            cmdline="root=UUID=$ROOT_UUID rootflags=subvol=$ROOT_SUBVOL rw quiet splash loglevel=3 rd.udev.log_priority=3"
        else
            cmdline="root=UUID=$ROOT_UUID rw quiet splash loglevel=3 rd.udev.log_priority=3"
        fi
    fi
    cmdline="$cmdline $ostree_param"

    entry_file="$ESP/loader/entries/ostree-$deploy_id.conf"
    if ! cat > "$entry_file" <<BLSENTRY
## This is a boot loader entry for ostree based on Ark Linux
title $title
version $kver
options $cmdline
linux /ostree/$deploy_id/vmlinuz-$kver
initrd /ostree/$deploy_id/initramfs-$kver.img
BLSENTRY
    then
        echo "bls-sync: Failed to write entry for $deploy_id (disk full?)"
        rm -f "$entry_file" 2>/dev/null || true
        continue
    fi

    # When /boot is on btrfs (not ESP), mirror kernel/initramfs + BLS entry there
    # so bootc can find a matching entry in /boot/loader/entries/
    if [ -n "$BOOT_DIR" ]; then
        boot_ostree="$BOOT_DIR/ostree/$deploy_id"
        mkdir -p "$boot_ostree"
        if [ ! -f "$boot_ostree/vmlinuz-$kver" ] || [ "$vmlinuz_src" -nt "$boot_ostree/vmlinuz-$kver" ]; then
            cp -f "$vmlinuz_dst" "$boot_ostree/vmlinuz-$kver" 2>/dev/null || \
            cp -f "$vmlinuz_src" "$boot_ostree/vmlinuz-$kver" 2>/dev/null || true
        fi
        if [ -f "$initramfs_dst" ]; then
            if [ ! -f "$boot_ostree/initramfs-$kver.img" ] || [ "$initramfs_dst" -nt "$boot_ostree/initramfs-$kver.img" ]; then
                cp -f "$initramfs_dst" "$boot_ostree/initramfs-$kver.img" 2>/dev/null || true
            fi
        fi

        boot_entry="$BOOT_DIR/loader.0/entries/ostree-$deploy_id.conf"
        mkdir -p "$BOOT_DIR/loader.0/entries"
        if ! cat > "$boot_entry" <<BLSENTRY
## This is a boot loader entry for ostree based on Ark Linux
title $title
version $kver
options $cmdline
linux /ostree/$deploy_id/vmlinuz-$kver
initrd /ostree/$deploy_id/initramfs-$kver.img
BLSENTRY
        then
            echo "bls-sync: Failed to write /boot entry for $deploy_id"
        fi

        # Ensure /boot/loader symlink points to loader.0
        if [ -L "$BOOT_DIR/loader" ] && [ "$(readlink "$BOOT_DIR/loader")" != "loader.0" ]; then
            ln -sfn "loader.0" "$BOOT_DIR/loader"
            echo "bls-sync: Updated /boot/loader symlink → loader.0"
        fi
    fi

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

# Hapus semua entry yang title-nya mengandung "(ostree:" — format auto-generated bootc/ostree
for entry in "$ESP/loader/entries/"*.conf; do
    [ ! -f "$entry" ] && continue
    if grep -q "title.*ostree:" "$entry" 2>/dev/null; then
        echo "bls-sync: Removing auto-generated entry $(basename $entry)"
        rm -f "$entry"
    fi
done

if [ ! -f "$ESP/loader/loader.conf" ]; then
    cat > "$ESP/loader/loader.conf" <<LOADER
timeout 3
console-mode max
default @
LOADER
fi

# Mirror cleanup to /boot (btrfs) when separate from ESP
if [ -n "$BOOT_DIR" ] && [ -d "$BOOT_DIR/loader.0/entries" ]; then
    for entry in "$BOOT_DIR/loader.0/entries/ostree-"*.conf; do
        [ ! -f "$entry" ] && continue
        id=$(basename "$entry" .conf | sed 's/^ostree-//')
        found=0
        for d in $deployments; do
            d=$(echo "$d" | tr -d '\n\r ')
            [ "$id" = "$d" ] && found=1 && break
        done
        if [ "$found" = "0" ]; then
            echo "bls-sync: Removing stale /boot entry $id"
            rm -f "$entry"
            rm -rf "$BOOT_DIR/ostree/$id" 2>/dev/null || true
        fi
    done

    # Remove auto-generated bootc entries from /boot
    for entry in "$BOOT_DIR/loader.0/entries/"*.conf; do
        [ ! -f "$entry" ] && continue
        if grep -q "title.*ostree:" "$entry" 2>/dev/null; then
            echo "bls-sync: Removing auto-generated /boot entry $(basename $entry)"
            rm -f "$entry"
        fi
    done

    # Clean up stale /boot loader dirs (loader.1, etc.) with old entries
    for _old_loader in "$BOOT_DIR"/loader.*/; do
        [ ! -d "$_old_loader" ] && continue
        _old_name=$(basename "$_old_loader")
        [ "$_old_name" = "loader.0" ] && continue
        [ -f "$_old_loader/loader.conf" ] && continue
        echo "bls-sync: Removing stale /boot/$_old_name"
        rm -rf "$_old_loader" 2>/dev/null || true
    done
fi

mount -o remount,ro "$SYSROOT" 2>/dev/null || true
