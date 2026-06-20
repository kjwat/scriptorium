#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
family="$($ROOT/scripts/detect-platform.sh)"

case "$family" in
    debian)
        sudo apt update
        sudo apt install -y \
            build-essential pkg-config libncursesw5-dev libcurl4-openssl-dev \
            git mpv poppler-utils pandoc \
            nano zip unzip xdg-utils file less pulseaudio-utils \
            mutt  calcurse links curl ca-certificates rsync
        ;;
    void)
        sudo xbps-install -Sy \
            base-devel pkg-config ncurses-devel libcurl-devel \
            git mpv poppler-utils pandoc \
            nano zip unzip xdg-utils file less pulseaudio-utils \
            mutt  calcurse links curl ca-certificates rsync
        ;;
    arch)
        sudo pacman -Syu --needed \
            base-devel pkgconf ncurses curl \
            git mpv poppler pandoc-cli \
            nano zip unzip xdg-utils file less libpulse \
            mutt  calcurse links ca-certificates rsync
        ;;
    alpine)
        sudo apk add \
            build-base pkgconf ncurses-dev curl-dev \
            git mpv poppler-utils pandoc \
            nano zip unzip xdg-utils file less pulseaudio-utils \
            mutt  calcurse links ca-certificates rsync
        ;;
    fedora)
        sudo dnf install -y \
            gcc make pkgconf-pkg-config ncurses-devel libcurl-devel \
            git mpv poppler-utils pandoc \
            nano zip unzip xdg-utils file less pulseaudio-utils \
            mutt  calcurse links curl ca-certificates rsync
        ;;
    suse)
        sudo zypper install -y \
            gcc make pkg-config ncurses-devel libcurl-devel \
            git mpv poppler-tools pandoc \
            nano zip unzip xdg-utils file less pulseaudio-utils \
            mutt  calcurse links curl ca-certificates rsync
        ;;
    macos)
        brew install \
            pkg-config ncurses curl make \
            git mpv poppler pandoc \
            nano zip unzip file less \
            mutt  calcurse links rsync
        ;;
    *)
        echo "Unknown platform family: $family" >&2
        echo "Install packages manually, then re-run ./install.sh" >&2
        exit 1
        ;;
esac
