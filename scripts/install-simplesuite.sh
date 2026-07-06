#!/usr/bin/env bash
set -euo pipefail

REPO_URL="${SIMPLESUITE_REPO_URL:-https://github.com/kjwat/simplesuite.git}"
DEST="${SIMPLESUITE_DIR:-$HOME/simplesuite}"
SIMPLESUITE_PROGRAMS="
simplebrowse
simplecal
simpleclock
simplefiles
simpleflac
simplegame
simplemail
simplepdf
simplepod
simpleradio
simplenews
simplestats
simplever
simplevis
simplewords

SIMPLESUITE_SCRIPTS="

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

echo "Verifying SimpleSuite binaries in $HOME/.local/bin"
missing=0
for program in $SIMPLESUITE_PROGRAMS; do
    if [ -x "$HOME/.local/bin/$program" ]; then
        printf '  ok: %s\n' "$program"
    else
        printf '  missing: %s\n' "$HOME/.local/bin/$program" >&2
        missing=1
    fi
done

if [ "$missing" -ne 0 ]; then
    echo "SimpleSuite build/install did not produce every expected binary." >&2
    exit 1
fi

echo "Verifying SimpleSuite helper scripts in $HOME/.local/bin"
for program in $SIMPLESUITE_SCRIPTS; do
    if [ -x "$HOME/.local/bin/$program" ]; then
        printf '  ok: %s\n' "$program"
    else
        printf '  missing: %s\n' "$HOME/.local/bin/$program" >&2
        missing=1
    fi
done

if [ "$missing" -ne 0 ]; then
    echo "SimpleSuite build/install did not produce every expected helper script." >&2
    exit 1
fi

if [ -x "$HOME/.local/bin/simplecal" ]; then
    "$HOME/.local/bin/simplecal" --install-reminders || echo "Warning: SimpleCal reminder setup failed; run simplecal --install-reminders later." >&2
elif command -v simplecal >/dev/null 2>&1; then
    simplecal --install-reminders || echo "Warning: SimpleCal reminder setup failed; run simplecal --install-reminders later." >&2
fi
