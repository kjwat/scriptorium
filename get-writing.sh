#!/usr/bin/env bash
set -e

TARGET="$HOME/writing"
REPO="https://github.com/kjwat/writing.git"
TMP="$HOME/.writing-clone-tmp"

rm -rf "$TMP"

if [ -d "$TARGET/.git" ]; then
  echo "Updating existing writing repo..."
  git -C "$TARGET" pull
  exit 0
fi

mkdir -p "$TARGET"

echo "Cloning writing repo into temporary directory..."
GIT_TERMINAL_PROMPT=1 git clone "$REPO" "$TMP"

echo "Copying repo into $TARGET while preserving existing autosaves..."
rsync -a --ignore-existing "$TMP"/ "$TARGET"/

rm -rf "$TMP"

echo "Done. Existing files were preserved."