#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SSH_SRC="$ROOT/dotfiles/ssh"
SSH_DST="$HOME/.ssh"

[ -d "$SSH_SRC" ] || exit 0

mkdir -p "$SSH_DST"

cp "$SSH_SRC/id_ed25519" "$SSH_DST/id_ed25519"
cp "$SSH_SRC/id_ed25519.pub" "$SSH_DST/id_ed25519.pub"
cp "$SSH_SRC/config" "$SSH_DST/config"

chmod 700 "$SSH_DST"
chmod 600 "$SSH_DST/id_ed25519"
chmod 644 "$SSH_DST/id_ed25519.pub"
chmod 600 "$SSH_DST/config"

ssh-keyscan github.com >> "$SSH_DST/known_hosts" 2>/dev/null || true

echo "SSH keys installed."
