#!/bin/bash
exec distrobox enter --root archlinux -- pacman "$@"
