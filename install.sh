#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

say() { printf '\n==> %s\n' "$*"; }
warn() { printf '\n!! %s\n' "$*" >&2; }

say "Scriptorium installer"

# Configure Git identity if missing
if ! git config --global user.name >/dev/null 2>&1; then
    printf "Enter your Git name: "
    read -r git_name
    git config --global user.name "$git_name"
fi

if ! git config --global user.email >/dev/null 2>&1; then
    printf "Enter your Git email: "
    read -r git_email
    git config --global user.email "$git_email"
fi

say "Preparing user PATH"
mkdir -p "$HOME/.local/bin"

PATH_LINE='export PATH="$HOME/.local/bin:$PATH"'

grep -qxF "$PATH_LINE" "$HOME/.bashrc" 2>/dev/null || {
    printf '\n# Scriptorium user binaries\n%s\n' "$PATH_LINE" >> "$HOME/.bashrc"
}

export PATH="$HOME/.local/bin:$PATH"
hash -r

say "Installing package dependencies"
"$ROOT/scripts/install-packages.sh"

say "Installing SimpleSuite"
"$ROOT/scripts/install-simplesuite.sh"

say "Linking dotfiles"
"$ROOT/scripts/link-dotfiles.sh"

say "Creating standard directories"
mkdir -p "$HOME/Downloads" "$HOME/Music" "$HOME/Podcasts"

export PATH="$HOME/.local/bin:$PATH"
hash -r

say "Verifying commands"
for cmd in simplewords simplefiles simplever simpleflac simpleradio simplepod simplepdf simplestats simpleclock simplegame simplevis; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        warn "$cmd was installed but is not available on PATH"
        exit 1
    fi
done

say "Done. The Scriptorium is installed and on PATH."

exec bash -l
