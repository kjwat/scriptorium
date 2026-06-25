#!/usr/bin/env bash
set -euo pipefail

REPO_URL="${SIMPLESUITE_REPO_URL:-https://github.com/kjwat/simplesuite.git}"
DEST="${SIMPLESUITE_DIR:-$HOME/simplesuite}"

mkdir -p "$(dirname "$DEST")"

if [ -d "$DEST/.git" ]; then
    echo "SimpleSuite already cloned at $DEST"
    if ! git -C "$DEST" pull --ff-only; then
        echo "Failed to update SimpleSuite at $DEST with git pull --ff-only." >&2
        echo "Resolve the checkout state, then rerun the Scriptorium installer." >&2
        exit 1
    fi
else
    git clone "$REPO_URL" "$DEST"
fi

if [ -x "$DEST/checkdeps.sh" ]; then
    "$DEST/checkdeps.sh" || true
fi

if [ -x "$DEST/build.sh" ]; then
    (cd "$DEST" && ./build.sh)
elif [ -f "$DEST/Makefile" ]; then
    (cd "$DEST" && make install)
else
    echo "No build.sh or Makefile found in $DEST" >&2
    exit 1
fi
