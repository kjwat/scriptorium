#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

say() { printf '\n==> %s\n' "$*"; }
warn() { printf '\n!! %s\n' "$*" >&2; }

say "Scriptorium installer"

say "Installing package dependencies"
"$ROOT/scripts/install-packages.sh"

say "Installing SimpleSuite"
"$ROOT/scripts/install-simplesuite.sh"

say "Linking dotfiles"
"$ROOT/scripts/link-dotfiles.sh"

say "Creating standard directories"
mkdir -p "$HOME/Downloads" "$HOME/Music" "$HOME/Podcasts"

say "Done. The Scriptorium is installed."
