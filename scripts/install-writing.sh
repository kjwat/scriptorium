#!/usr/bin/env bash
set -euo pipefail

REPO_URL="${WRITING_REPO_URL:-https://github.com/kjwat/writing.git}"
DEST="${WRITING_DIR:-$HOME/writing}"

if [ -d "$DEST/.git" ]; then
    echo "Writing repo already exists at $DEST"
    git -C "$DEST" pull --ff-only || true
    exit 0
fi

if [ -e "$DEST" ]; then
    echo "Refusing to overwrite existing non-git path: $DEST" >&2
    exit 1
fi

git clone "$REPO_URL" "$DEST"
echo "Writing repo installed at $DEST"
