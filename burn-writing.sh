#!/usr/bin/env bash
set -euo pipefail

DEST="${WRITING_DIR:-$HOME/writing}"

echo
echo "This will remove:"
echo "  - $DEST"
echo "  - credential traces for kjwat/writing only"
echo
printf "Type BURN-WRITING to continue: "
read ans

[ "$ans" = "BURN-WRITING" ] || {
    echo "Cancelled."
    exit 1
}

rm -rf "$DEST"

if [ -f "$HOME/.git-credentials" ]; then
    tmp="$(mktemp)"
    grep -vE 'github\.com[:/]+kjwat/writing|github\.com.*kjwat.*writing' "$HOME/.git-credentials" > "$tmp" || true
    mv "$tmp" "$HOME/.git-credentials"
    chmod 600 "$HOME/.git-credentials"
fi

if command -v git >/dev/null 2>&1; then
    printf 'protocol=https\nhost=github.com\npath=kjwat/writing\n\n' | git credential reject || true
    printf 'protocol=https\nhost=github.com\nusername=kjwat\n\n' | git credential reject || true
fi

echo "Writing repo and kjwat/writing traces removed."
