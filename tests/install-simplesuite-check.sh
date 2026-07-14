#!/usr/bin/env bash
set -euo pipefail

SOURCE_ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/scriptorium-suite-check.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

export HOME="$TMP/home"
FAKE_SCRIPTORIUM="$TMP/scriptorium"
FAKE_REPO="$TMP/simple-source"
FAKE_BIN="$TMP/test-bin"
mkdir -p "$HOME" "$FAKE_SCRIPTORIUM/scripts" "$FAKE_REPO" "$FAKE_BIN"

cp "$SOURCE_ROOT/scripts/install-simplesuite.sh" \
    "$FAKE_SCRIPTORIUM/scripts/install-simplesuite.sh"
printf '%s\n' '#!/bin/sh' 'exit 0' >"$FAKE_SCRIPTORIUM/scripts/checkdeps.sh"
chmod 755 "$FAKE_SCRIPTORIUM/scripts/checkdeps.sh"

cat >"$FAKE_BIN/uname" <<'EOF'
#!/bin/sh
echo Linux
EOF
chmod 755 "$FAKE_BIN/uname"

cat >"$FAKE_REPO/build.sh" <<'EOF'
#!/bin/sh
set -eu

programs='simplebrowse simplecal simpleclock simplefiles simpleflac simplegame simplemail simplepdf simplepod simpleradio simplenews simplestats simplever simplevis simplewords'
helpers='simplebrowse-webkitd simplebrowse-jsdump simplesuite-uninstall'
assets='simplecal-alarm.mp3 simplewords-typewriter.wav simplewords-typewriter-alt.wav simplewords-typewriter-space.wav simplewords-typewriter-enter.wav simplewords-typewriter-delete.wav simplewords-typewriter-NOTICE.md install-source'

mkdir -p "$HOME/.local/bin" "$HOME/.local/share/simplesuite" \
    "$HOME/.config/simplewords"
for name in $programs $helpers; do
    printf '%s\n' '#!/bin/sh' 'exit 0' >"$HOME/.local/bin/$name"
    chmod 755 "$HOME/.local/bin/$name"
done
for name in $assets; do
    printf '%s\n' fixture >"$HOME/.local/share/simplesuite/$name"
done
if [ ! -e "$HOME/.config/simplewords/config" ]; then
    printf '%s\n' 'typewriter_sound=false' 'typewriter_sound_volume=70' \
        >"$HOME/.config/simplewords/config"
fi
EOF
chmod 755 "$FAKE_REPO/build.sh"

git -C "$FAKE_REPO" init -q
git -C "$FAKE_REPO" config user.name 'Scriptorium test'
git -C "$FAKE_REPO" config user.email 'test@example.invalid'
git -C "$FAKE_REPO" add build.sh
git -C "$FAKE_REPO" commit -qm fixture

PATH="$FAKE_BIN:/usr/bin:/bin" \
SIMPLESUITE_REPO_URL="$FAKE_REPO" \
SIMPLESUITE_DIR="$HOME/simplesuite" \
SIMPLESUITE_INSTALL_REMINDERS=0 \
    "$FAKE_SCRIPTORIUM/scripts/install-simplesuite.sh" \
    >"$TMP/install.log"

[[ -x "$HOME/.local/bin/simplewords" ]]
[[ -x "$HOME/.local/bin/simplesuite-uninstall" ]]
[[ -r "$HOME/.local/share/simplesuite/simplewords-typewriter.wav" ]]
[[ -r "$HOME/.local/share/simplesuite/simplewords-typewriter-NOTICE.md" ]]
[[ -r "$HOME/.local/share/simplesuite/install-source" ]]
grep -q '^typewriter_sound=false$' "$HOME/.config/simplewords/config"
grep -q '^typewriter_sound_volume=70$' "$HOME/.config/simplewords/config"

echo 'OK Scriptorium verifies the complete SimpleSuite runtime payload'
