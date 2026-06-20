#!/usr/bin/env bash
set -euo pipefail

DEST="${WRITING_DIR:-$HOME/writing}"

echo
echo "This will remove:"
echo "  $DEST"
echo
printf "Type BURN-WRITING to continue: "
read ans

[ "$ans" = "BURN-WRITING" ] || {
    echo "Cancelled."
    exit 1
}

rm -rf "$DEST"
echo "Writing repo removed."
