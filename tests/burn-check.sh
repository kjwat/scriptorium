#!/usr/bin/env bash
set -euo pipefail

SOURCE_ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/scriptorium-burn-check.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

export HOME="$TMP/home"
FAKE_ROOT="$HOME/scriptorium"
FAKE_SUITE="$HOME/simplesuite"
FAKE_BIN="$TMP/test-bin"
REAL_BASH_DIR="$(dirname "$(command -v bash)")"
mkdir -p "$FAKE_ROOT" "$FAKE_SUITE" "$FAKE_BIN" "$HOME/.local/bin"
cp "$SOURCE_ROOT/burn.sh" "$SOURCE_ROOT/burn-writing.sh" "$FAKE_ROOT/"

fail() {
    printf 'burn-check: %s\n' "$*" >&2
    exit 1
}

assert_missing() {
    [[ ! -e "$1" && ! -L "$1" ]] || fail "expected removal: $1"
}

for stub in systemctl crontab git; do
    printf '%s\n' '#!/bin/sh' 'exit 0' >"$FAKE_BIN/$stub"
    chmod 755 "$FAKE_BIN/$stub"
done

cat >"$FAKE_BIN/uname" <<'EOF'
#!/bin/sh
echo FreeBSD
EOF
chmod 755 "$FAKE_BIN/uname"

cat >"$HOME/.local/bin/simplesuite-uninstall" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >"$HOME/native-burn-args"
exit 0
EOF
chmod 755 "$HOME/.local/bin/simplesuite-uninstall"

programs='simplewords simplecheck simplefiles simplebrowse simplebrowse-webkitd simplebrowse-jsdump simpleflac simpleradio simplepod simplevis simplepdf simpleclock simplecal simplestats simplever simplegame simplenews simplemail simplenet simpleserve simpleserved setup-server'
for program in $programs; do
    printf '%s\n' '#!/bin/sh' >"$HOME/.local/bin/$program"
    chmod 755 "$HOME/.local/bin/$program"
done

mkdir -p \
    "$HOME/writing" \
    "$HOME/.writing-clone-tmp" \
    "$HOME/.config/scriptorium" \
    "$HOME/.config/simplewords" \
    "$HOME/.config/simplesuite" \
    "$HOME/.config/isyncrc-target" \
    "$HOME/.cache/simplewords" \
    "$HOME/xdg-cache/simplepdf" \
    "$HOME/.local/state/simplewords" \
    "$HOME/.local/share/simplemail/mail/Inbox/cur" \
    "$HOME/.local/share/simplesuite" \
    "$HOME/.scriptorium-backups/old"

printf '%s\n' 'typewriter_sound=false' 'typewriter_sound_volume=70' \
    >"$HOME/.config/simplewords/config"
printf '%s\n' keep >"$HOME/.local/share/simplemail/mail/Inbox/cur/message"
printf '%s\n' keep >"$HOME/unrelated-file"
printf '%s\n' keep >"$HOME/.writing-clone-tmp/partial"
printf '%s\n' keep >"$HOME/.scriptorium-backups/old/config"
printf '%s\n' keep >"$HOME/.config/scriptorium/legacy-marker"
printf '%s\n' keep >"$HOME/xdg-cache/simplepdf/document.txt"
printf '%s\n' keep >"$FAKE_SUITE/simplewords.c"

FAKE_FREEBSD_HELPER="$HOME/system-libexec/simplefiles-freebsd-unmount"
mkdir -p "$(dirname "$FAKE_FREEBSD_HELPER")"
printf '%s\n' '#!/bin/sh' 'exit 0' >"$FAKE_FREEBSD_HELPER"
chmod 755 "$FAKE_FREEBSD_HELPER"

FAKE_SIMPLESERVE_DAEMON="$HOME/system-sbin/simpleserved"
FAKE_SIMPLESERVE_UNINSTALLER="$HOME/system-sbin/simpleserve-system-uninstall"
mkdir -p "$(dirname "$FAKE_SIMPLESERVE_DAEMON")"
printf '%s\n' '#!/bin/sh' 'exit 0' >"$FAKE_SIMPLESERVE_DAEMON"
cat >"$FAKE_SIMPLESERVE_UNINSTALLER" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >"$HOME/system-uninstall-args"
rm -f "$SIMPLESERVE_SYSTEM_DAEMON" "$SIMPLESERVE_SYSTEM_UNINSTALLER"
EOF
chmod 755 "$FAKE_SIMPLESERVE_DAEMON" "$FAKE_SIMPLESERVE_UNINSTALLER"

assets='simplecal-alarm.mp3 simplewords-typewriter.wav simplewords-typewriter-alt.wav simplewords-typewriter-space.wav simplewords-typewriter-enter.wav simplewords-typewriter-delete.wav simplewords-typewriter-NOTICE.md install-source simplewords-typewriter.wav.bak simplewords-typewriter.wav.bak2'
for asset in $assets; do
    printf '%s\n' keep >"$HOME/.local/share/simplesuite/$asset"
done

cat >"$HOME/.mbsyncrc" <<'EOF'
# unrelated mail setting
KeepThis yes
# BEGIN SCRIPTORIUM SIMPLEMAIL GMAIL
Pass "secret"
# END SCRIPTORIUM SIMPLEMAIL GMAIL
EOF
ln -s "$HOME/.mbsyncrc" "$HOME/.config/isyncrc"

printf '%s\n' BURN | \
    PATH="$FAKE_BIN:$REAL_BASH_DIR:/usr/local/bin:/usr/bin:/bin" \
    XDG_CACHE_HOME="$HOME/xdg-cache" \
    FREEBSD_UNMOUNT_HELPER="$FAKE_FREEBSD_HELPER" \
    SIMPLESERVE_SYSTEM_DAEMON="$FAKE_SIMPLESERVE_DAEMON" \
    SIMPLESERVE_SYSTEM_UNINSTALLER="$FAKE_SIMPLESERVE_UNINSTALLER" \
    SIMPLESERVE_SYSTEM_TEST_MODE=1 \
    SIMPLESUITE_DIR="$FAKE_SUITE" \
    "$FAKE_ROOT/burn.sh" >"$TMP/burn.log"

[[ "$(cat "$HOME/native-burn-args")" == '--burn --yes' ]] ||
    fail "burn.sh did not invoke SimpleSuite native burn with confirmation"

assert_missing "$FAKE_ROOT"
assert_missing "$FAKE_SUITE"
assert_missing "$HOME/writing"
assert_missing "$HOME/.writing-clone-tmp"
assert_missing "$HOME/.config/simplewords"
assert_missing "$HOME/.config/scriptorium"
assert_missing "$HOME/.config/simplesuite"
assert_missing "$HOME/.config/isyncrc"
assert_missing "$HOME/.cache/simplewords"
assert_missing "$HOME/xdg-cache/simplepdf"
assert_missing "$HOME/.local/state/simplewords"
assert_missing "$HOME/.local/share/simplemail"
assert_missing "$HOME/.local/share/simplesuite"
assert_missing "$HOME/.scriptorium-backups"
assert_missing "$FAKE_FREEBSD_HELPER"
assert_missing "$FAKE_SIMPLESERVE_DAEMON"
assert_missing "$FAKE_SIMPLESERVE_UNINSTALLER"
[[ "$(cat "$HOME/system-uninstall-args")" == '--purge' ]] ||
    fail "burn.sh did not purge the SimpleServe system service"

for program in $programs simplesuite-uninstall; do
    assert_missing "$HOME/.local/bin/$program"
done

[[ -f "$HOME/unrelated-file" ]] || fail "burn removed an unrelated file"
grep -q '^KeepThis yes$' "$HOME/.mbsyncrc" ||
    fail "burn removed unrelated mbsync configuration"
if grep -q 'SCRIPTORIUM SIMPLEMAIL\|Pass "secret"' "$HOME/.mbsyncrc"; then
    fail "burn left Scriptorium mail credentials"
fi

echo 'OK Scriptorium burn covers the native and fallback SimpleSuite payload'
