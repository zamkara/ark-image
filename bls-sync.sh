#!/bin/bash
mount -o remount,rw /sysroot 2>/dev/null || true
ORIG=$(ostree config --repo=/sysroot/ostree/repo get sysroot.bootloader 2>/dev/null || echo none)
ostree config --repo=/sysroot/ostree/repo set sysroot.bootloader grub2
ostree admin bootloader-update --sysroot=/sysroot 2>/dev/null || true
ostree config --repo=/sysroot/ostree/repo set sysroot.bootloader "$ORIG"
mount -o remount,ro /sysroot 2>/dev/null || true
