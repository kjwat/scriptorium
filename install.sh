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

# Remember HTTPS GitHub/PAT credentials after first successful push.
# This stores credentials in ~/.git-credentials.
git config --global credential.helper store

say "Preparing user PATH"
mkdir -p "$HOME/.local/bin"

PATH_LINE='export PATH="$HOME/.local/bin:$PATH"'

grep -qxF "$PATH_LINE" "$HOME/.bashrc" 2>/dev/null || {
    printf '\n# Scriptorium user binaries\n%s\n' "$PATH_LINE" >> "$HOME/.bashrc"
}

grep -q "^# SimpleSuite aliases$" "$HOME/.bashrc" 2>/dev/null || cat >> "$HOME/.bashrc" <<'ALIASES'

# SimpleSuite aliases
alias words='simplewords'
alias files='simplefiles'
alias flac='simpleflac'
alias radio='simpleradio'
alias pod='simplepod'
alias vis='simplevis'
alias clock='simpleclock'
alias stats='simplestats'
alias ver='simplever'
alias game='simplegame'
alias pdf='simplepdf'
ALIASES

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

say "Verifying commands"
for cmd in simplewords simplefiles simplever simpleflac simpleradio simplepod simplepdf simplestats simpleclock simplegame simplevis; do
    command -v "$cmd" >/dev/null 2>&1 || {
        warn "$cmd was installed but is not available on PATH"
        exit 1
    }
done

say "Done. The Scriptorium is installed."
exec bash -l
