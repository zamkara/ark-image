# Ark OS Image 📦

This repository contains the `Containerfile` and build logic for **Ark OS**.

**Ark OS is NOT a separate distribution.** It is simply vanilla Arch Linux delivered as a modern, immutable, container-native operating system. It leverages `bootc` and OSTree to provide reliable, atomic updates. By using OCI containers as the base system, every installation is perfectly reproducible and can be updated seamlessly via standard container image pulls.

## Structure
- **Containerfile**: The recipe for the OS. It uses `archlinux:latest` as a base, installs all the necessary packages (including GNOME, Flatpak, network manager, and kernel), and sets up the OSTree bindings.
- **GitHub Actions**: The image is automatically built and pushed to the GitHub Container Registry (`ghcr.io`) upon every commit.

## Variants
The `Containerfile` is designed to be flexible. By passing different `VARIANT` arguments during the build, you can generate different kernels or features:
- `ark-zen-nvidia`: Builds the system with the `linux-zen` kernel and proprietary NVIDIA drivers.

## Usage / Installation
You generally do not need to build this image manually unless you are developing it. 
End-users should use the **Ark Wizard (alga)** Live ISO to automatically install this image onto their hardware.

If you are a developer testing local builds:
```bash
# Build the image locally
podman build -t localhost/ark-image:test --build-arg VARIANT="ark-zen-nvidia" .

# To install it directly (destructive to disk!):
# bootc install to-disk /dev/sdX
```

## Customization
To add new default software, simply modify the `pacman -S` list within the `Containerfile`. Everything is managed declaratively!

## License
MIT License
