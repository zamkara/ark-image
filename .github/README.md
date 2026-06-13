# ark-image

OCI container image build logic for an immutable Arch Linux system.

This repository defines the base `Containerfile` used to provision the OSTree deployment. It builds upon `archlinux:latest` and integrates `bootc` to enable atomic system updates. It is strictly vanilla Arch Linux, packaged as an immutable container.

## Build arguments
- `VARIANT`: Specifies kernel and driver combinations (e.g., `ark-zen-nvidia`).

## Local Build
```bash
podman build -t localhost/ark-image:test --build-arg VARIANT="ark-zen-nvidia" .
```

## System Deployment
Deployment requires a bootable environment containing `bootc`. See the [ark.linux](https://github.com/zamkara/ark.linux) Live ISO or the [alga](https://github.com/zamkara/alga) installer frontend.

## License
MIT
