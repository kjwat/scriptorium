#!/usr/bin/env bash
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "==> Checking for snap..."

if ! command -v snap >/dev/null 2>&1; then
    echo "snap not found."

    if command -v apt >/dev/null 2>&1; then
        sudo apt update
        sudo apt install -y snapd
    elif command -v dnf >/dev/null 2>&1; then
        sudo dnf install -y snapd
        sudo systemctl enable --now snapd.socket
        sudo ln -sf /var/lib/snapd/snap /snap
    elif command -v pacman >/dev/null 2>&1; then
        echo "snapd is not usually preinstalled on Arch."
        echo "Install snapd from AUR, then rerun this script."
        exit 1
    else
        echo "No supported snap install method found."
        exit 1
    fi
fi

echo "==> Installing Newsboat snap..."
sudo snap install newsboat || true

echo "==> Linking Newsboat dotfiles..."

mkdir -p "$HOME/snap/newsboat/current/.newsboat"

if [ -f "$ROOT/dotfiles/newsboat/urls" ]; then
    cp "$ROOT/dotfiles/newsboat/urls" "$HOME/snap/newsboat/current/.newsboat/urls"
else
    echo "Missing: $ROOT/dotfiles/newsboat/urls"
fi

if [ -f "$ROOT/dotfiles/newsboat/config" ]; then
    cp "$ROOT/dotfiles/newsboat/config" "$HOME/snap/newsboat/current/.newsboat/config"
else
    echo "Missing: $ROOT/dotfiles/newsboat/config"
fi

echo
echo "Done."
echo "Run Newsboat with:"
echo
echo "  snap run newsboat"
echo
