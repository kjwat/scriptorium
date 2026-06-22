#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
family="$("$ROOT/scripts/detect-platform.sh")"

if [ "$family" = unknown ]; then
    family_file=$HOME/.config/simplesuite/family

    if [ -f "$family_file" ]; then
        saved_family=
        IFS= read -r saved_family < "$family_file" || true

        case "$saved_family" in
            debian | arch | fedora | alpine | void | suse)
                family=$saved_family
                ;;
            *)
                printf 'Invalid saved package family in %s\n' "$family_file" >&2
                exit 1
                ;;
        esac
    else
        printf '\nUnknown system detected.\n\n'
        while :; do
            printf '%s\n' \
                'Select package family:' \
                '1) debian (apt)' \
                '2) arch (pacman)' \
                '3) fedora (dnf)' \
                '4) alpine (apk)' \
                '5) void (xbps)' \
                '6) suse (zypper)'
            printf '\nEnter choice: '

            if ! IFS= read -r choice; then
                printf '\nUnable to read package family selection.\n' >&2
                exit 1
            fi

            case "$choice" in
                1) family=debian ;;
                2) family=arch ;;
                3) family=fedora ;;
                4) family=alpine ;;
                5) family=void ;;
                6) family=suse ;;
                *)
                    printf '\nInvalid choice. Enter a number from 1 to 6.\n\n' >&2
                    continue
                    ;;
            esac
            break
        done

        mkdir -p "$HOME/.config/simplesuite"
        printf '%s\n' "$family" > "$family_file"
        chmod 600 "$family_file"
    fi
fi

case "$family" in
    debian)
        sudo apt update
        sudo apt install -y \
            build-essential pkg-config libncursesw5-dev libcurl4-openssl-dev \
            git mpv poppler-utils pandoc \
            nano zip unzip xdg-utils file less fzf pulseaudio-utils \
            mutt  calcurse links curl ca-certificates rsync
        ;;
    void)
        sudo xbps-install -Sy \
            base-devel pkg-config ncurses-devel libcurl-devel \
            git mpv poppler-utils pandoc \
            nano zip unzip xdg-utils file less fzf pulseaudio-utils \
            mutt  calcurse links curl ca-certificates rsync
        ;;
    arch)
        sudo pacman -Syu --needed \
            base-devel pkgconf ncurses curl \
            git mpv poppler pandoc-cli \
            nano zip unzip xdg-utils file less fzf libpulse \
            mutt  calcurse links ca-certificates rsync
        ;;
    alpine)
        sudo apk add \
            build-base pkgconf ncurses-dev curl-dev \
            git mpv poppler-utils pandoc \
            nano zip unzip xdg-utils file less fzf pulseaudio-utils \
            mutt  calcurse links ca-certificates rsync
        ;;
    fedora)
        sudo dnf install -y \
            gcc make pkgconf-pkg-config ncurses-devel libcurl-devel \
            git mpv poppler-utils pandoc \
            nano zip unzip xdg-utils file less fzf pulseaudio-utils \
            mutt  calcurse links curl ca-certificates rsync
        ;;
    suse)
        sudo zypper install -y \
            gcc make pkg-config ncurses-devel libcurl-devel \
            git mpv poppler-tools pandoc \
            nano zip unzip xdg-utils file less fzf pulseaudio-utils \
            mutt  calcurse links curl ca-certificates rsync
        ;;
    macos)
        brew install \
            pkg-config ncurses curl make \
            git mpv poppler pandoc \
            nano zip unzip file less fzf \
            mutt  calcurse links rsync
        ;;
    *)
        echo "Unknown platform family: $family" >&2
        echo "Install packages manually, then re-run ./install.sh" >&2
        exit 1
        ;;
esac
