#!/bin/sh
set -eu

SOURCE_ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/scriptorium-suite-check.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

export HOME="$TMP/home"
FAKE_SCRIPTORIUM="$TMP/scriptorium"
FAKE_REPO="$TMP/simple-source"
FAKE_BIN="$TMP/test-bin"
REAL_GIT_DIR="$(dirname "$(command -v git)")"
SIMPLESUITE_SYSTEM_BIN_DIR="$TMP/system-bin"
SIMPLESERVE_DAEMON_BINARY="$TMP/system-sbin/simpleserved"
export SIMPLESUITE_SYSTEM_BIN_DIR SIMPLESERVE_DAEMON_BINARY
mkdir -p "$HOME" "$FAKE_SCRIPTORIUM/scripts" "$FAKE_REPO" "$FAKE_BIN" \
    "$SIMPLESUITE_SYSTEM_BIN_DIR" "${SIMPLESERVE_DAEMON_BINARY%/*}"
printf '%s\n' '#!/bin/sh' '# frozen SimpleOS daemon' 'exit 99' \
    >"$SIMPLESERVE_DAEMON_BINARY"
chmod 755 "$SIMPLESERVE_DAEMON_BINARY"
cat >"$FAKE_BIN/sudo" <<'EOF'
#!/bin/sh
exec "$@"
EOF
chmod 755 "$FAKE_BIN/sudo"
cat >"$FAKE_REPO/program-manifest.sh" <<'EOF'
simplesuite_program_aliases() {
    printf '%s\n' browse:simplebrowse cal:simplecal clock:simpleclock \
        files:simplefiles flac:simpleflac game:simplegame mail:simplemail \
        news:simplenews pdf:simplepdf pod:simplepod radio:simpleradio \
        stats:simplestats suite-uninstall:simplesuite-uninstall \
        ver:simplever vis:simplevis words:simplewords
    case $1 in Linux) printf '%s\n' net:simplenet blue:simpleblue ;; \
        FreeBSD) printf '%s\n' net:simplenet ;; esac
    [ "$2" = 1 ] && printf '%s\n' serve:simpleserve || :
}
simplesuite_programs() {
    simplesuite_program_aliases "$1" "$2" | sed '/simplesuite-uninstall$/d;s/.*://'
    [ "$2" = 1 ] && printf '%s\n' simpleserved || :
}
EOF

cp "$SOURCE_ROOT/scripts/install-simplesuite.sh" \
    "$FAKE_SCRIPTORIUM/scripts/install-simplesuite.sh"
cp "$SOURCE_ROOT/scripts/resolve-simpleserve-role.sh" \
    "$FAKE_SCRIPTORIUM/scripts/resolve-simpleserve-role.sh"
cp "$SOURCE_ROOT/scripts/bounded-command.sh" \
    "$FAKE_SCRIPTORIUM/scripts/bounded-command.sh"
printf '%s\n' '#!/bin/sh' 'exit 0' >"$FAKE_SCRIPTORIUM/scripts/checkdeps.sh"
chmod 755 "$FAKE_SCRIPTORIUM/scripts/checkdeps.sh"
printf '%s\n' '#!/bin/sh' 'printf "%s\n" yes >"$HOME/package-install-ran"' \
    >"$FAKE_SCRIPTORIUM/scripts/install-packages.sh"
chmod 755 "$FAKE_SCRIPTORIUM/scripts/install-packages.sh"

cat >"$FAKE_BIN/uname" <<'EOF'
#!/bin/sh
printf '%s\n' "${FAKE_UNAME:-FreeBSD}"
EOF
chmod 755 "$FAKE_BIN/uname"

cat >"$FAKE_BIN/brew" <<'EOF'
#!/bin/sh
set -eu
if [ "${1-}" = --prefix ] && [ -n "${2-}" ]; then
    prefix="$FAKE_BREW_ROOT/${2-}"
    mkdir -p "$prefix/lib/pkgconfig" "$prefix/share/pkgconfig"
    printf '%s\n' "$prefix"
    exit 0
fi
echo "unexpected brew arguments: $*" >&2
exit 2
EOF
chmod 755 "$FAKE_BIN/brew"

cat >"$FAKE_REPO/build.sh" <<'EOF'
#!/bin/sh
set -eu

[ "${SIMPLESUITE_REQUIRE_CLEAN:-}" = 1 ]
[ "${SIMPLESUITE_SOURCE_SHA:-}" = "$(git rev-parse --verify HEAD^{commit})" ]
[ "${SIMPLESUITE_INSTALL_SIMPLESERVE_SYSTEM:-}" = skip ]

programs='simplebrowse simplecal simpleclock simplefiles simpleflac simplegame simplemail simplepdf simplepod simpleradio simplenews simplestats simplever simplevis simplewords'
aliases='browse:simplebrowse cal:simplecal clock:simpleclock files:simplefiles flac:simpleflac game:simplegame mail:simplemail news:simplenews pdf:simplepdf pod:simplepod radio:simpleradio stats:simplestats suite-uninstall:simplesuite-uninstall ver:simplever vis:simplevis words:simplewords'
case "$(uname -s)" in
    Linux)
        programs="$programs simplenet simpleblue"
        aliases="$aliases net:simplenet blue:simpleblue"
        ;;
    FreeBSD)
        programs="$programs simplenet"
        aliases="$aliases net:simplenet"
        ;;
esac
case "$(uname -s)" in
    Darwin | FreeBSD | Linux)
        if [ "${SIMPLESUITE_INSTALL_SIMPLESERVE:-1}" -eq 1 ]; then
            programs="$programs simpleserve simpleserved"
            aliases="$aliases serve:simpleserve"
        fi
        ;;
esac
helpers='simplebrowse-webkitd simplebrowse-jsdump simplesuite-uninstall'
assets='simplecal-alarm.mp3 simplewords-typewriter.wav simplewords-typewriter-alt.wav simplewords-typewriter-space.wav simplewords-typewriter-enter.wav simplewords-typewriter-delete.wav simplewords-typewriter-NOTICE.md install-source install-manifest command-abbreviations program-manifest.sh'

mkdir -p "$HOME/.local/bin" "$HOME/.local/share/simplesuite" "$PWD/build" \
    "$HOME/.config/simplefiles" "$HOME/.config/simplemail" \
    "$HOME/.config/simplenews" "$HOME/.config/simplewords"
for name in $programs $helpers; do
    printf '%s\n' '#!/bin/sh' 'exit 0' >"$HOME/.local/bin/$name"
    chmod 755 "$HOME/.local/bin/$name"
    case $name in
        simplesuite-uninstall | simplebrowse-webkitd | simplebrowse-jsdump) ;;
        *)
            cp "$HOME/.local/bin/$name" "$PWD/build/$name"
            chmod 755 "$PWD/build/$name"
            ;;
    esac
done
cat >"$HOME/.local/bin/simplewords" <<SIMPLEWORDS_EOF
#!/bin/sh
if [ "\${1-}" = --version ]; then
    printf '%s\n' 'simplewords ${SIMPLESUITE_SOURCE_SHA:?}'
fi
exit 0
SIMPLEWORDS_EOF
chmod 755 "$HOME/.local/bin/simplewords"
cp "$HOME/.local/bin/simplewords" "$PWD/build/simplewords"
for mapping in $aliases; do
    short=${mapping%%:*}
    full=${mapping#*:}
    ln -s "$full" "$HOME/.local/bin/$short"
done
printf '%s\n' "${SIMPLESUITE_INSTALL_SIMPLESERVE:-unset}" \
    >"$HOME/simpleserve-component-selection"
printf '%s\n' "${SIMPLESUITE_NETWORK_ROLE:-unset}" \
    >"$HOME/simpleserve-network-role"
for name in $assets; do
    printf '%s\n' fixture >"$HOME/.local/share/simplesuite/$name"
done
printf 'simplesuite_source_sha=%s\nsimplewords_build_revision=%s\n' \
    "${SIMPLESUITE_SOURCE_SHA:?}" "${SIMPLESUITE_SOURCE_SHA:?}" \
    >"$HOME/.local/share/simplesuite/install-manifest"
if [ ! -e "$HOME/.config/simplewords/config" ]; then
    printf '%s\n' 'typewriter_sound=false' 'typewriter_sound_volume=70' \
        >"$HOME/.config/simplewords/config"
fi
printf '%s\n' 'TRASH_DIR=$HOME/.local/share/simplefiles/trash' \
    >"$HOME/.config/simplefiles/config"
printf '%s\n' 'maildir=$HOME/.local/share/simplemail/mail' \
    >"$HOME/.config/simplemail/config"
printf '%s\n' 'feed_timeout=18' \
    >"$HOME/.config/simplenews/config.example"
printf '%s\n' '# feeds' \
    >"$HOME/.config/simplenews/urls.example"

case "$(uname -s)" in
    FreeBSD)
        [ "${SIMPLESUITE_INSTALL_PACKAGES:-}" = 0 ]
        [ "${SIMPLESUITE_INSTALL_SIMPLESERVE:-}" = 1 ]
        [ "${SIMPLESUITE_NETWORK_ROLE:-}" = client ]
        [ "${SIMPLESUITE_INSTALL_FREEBSD_HELPER:-}" = require ]
        [ -n "${FREEBSD_UNMOUNT_HELPER:-}" ]
        mkdir -p "$(dirname "$FREEBSD_UNMOUNT_HELPER")"
        printf '%s\n' '#!/bin/sh' 'exit 0' >"$FREEBSD_UNMOUNT_HELPER"
        chmod 755 "$FREEBSD_UNMOUNT_HELPER"
        ;;
    Darwin)
        [ "${SIMPLESUITE_INSTALL_PACKAGES:-}" = 0 ]
        [ "${SIMPLESUITE_NETWORK_ROLE:-}" = client ]
        [ "${MAKE:-}" = gmake ]
        printf '%s\n' yes >"$HOME/macos-build-ran"
        ;;
    Linux)
        [ "${SIMPLESUITE_INSTALL_PACKAGES:-}" = auto ]
        if [ "${SIMPLESUITE_INSTALL_SIMPLESERVE:-}" = 1 ]; then
            case "${SIMPLESUITE_NETWORK_ROLE:-}" in
                client | server) ;;
                *) exit 1 ;;
            esac
        else
            [ "${SIMPLESUITE_NETWORK_ROLE:-}" = none ]
        fi
        [ -z "${MAKE:-}" ]
        printf '%s\n' yes >"$HOME/linux-build-ran"
        ;;
esac
EOF
chmod 755 "$FAKE_REPO/build.sh"

for helper in uninstall.sh simplebrowse-webkitd simplebrowse-jsdump; do
    printf '%s\n' '#!/bin/sh' 'exit 0' >"$FAKE_REPO/$helper"
    chmod 755 "$FAKE_REPO/$helper"
done
printf '%s\n' /build/ >"$FAKE_REPO/.gitignore"

cat >"$FAKE_REPO/verify-simpleserve-system.sh" <<'EOF'
#!/bin/sh
set -eu
[ "$#" -eq 2 ]
[ "$1" = "$SIMPLESERVE_DAEMON_BINARY" ]
[ "$2" = "$SIMPLESUITE_SYSTEM_BIN_DIR/simpleserve" ]
[ -x "$1" ] && [ -x "$2" ]
grep -q '^# frozen SimpleOS daemon$' "$1"
if [ "${FAKE_SERVICE_FAILURE:-0}" = 1 ]; then
    echo 'fixture: existing daemon is not responding' >&2
    exit 1
fi
printf '%s\n' yes >"$HOME/simpleserve-system-verified"
printf '%s\n' "${SIMPLESUITE_NETWORK_ROLE:-unset}" \
    >"$HOME/simpleserve-system-role-verified"
EOF
chmod 755 "$FAKE_REPO/verify-simpleserve-system.sh"

git -C "$FAKE_REPO" init -q
git -C "$FAKE_REPO" config user.name 'Scriptorium test'
git -C "$FAKE_REPO" config user.email 'test@example.invalid'
git -C "$FAKE_REPO" add build.sh program-manifest.sh .gitignore \
    verify-simpleserve-system.sh uninstall.sh simplebrowse-webkitd simplebrowse-jsdump
git -C "$FAKE_REPO" commit -qm fixture

SCRIPTORIUM_SIMPLESERVE_ROLE_FILE=$TMP/no-existing-role
export SCRIPTORIUM_SIMPLESERVE_ROLE_FILE

PATH="$FAKE_BIN:$REAL_GIT_DIR:/usr/local/bin:/usr/bin:/bin" \
FAKE_UNAME=FreeBSD \
FAKE_BREW_ROOT="$TMP/homebrew" \
SIMPLESUITE_REPO_URL="$FAKE_REPO" \
SIMPLESUITE_DIR="$HOME/simplesuite" \
SIMPLESUITE_INSTALL_REMINDERS=0 \
SIMPLESUITE_INSTALL_FREEBSD_HELPER=require \
SIMPLESUITE_INSTALL_SIMPLESERVE_SYSTEM=require \
FREEBSD_UNMOUNT_HELPER="$HOME/system-libexec/simplefiles-freebsd-unmount" \
    "$FAKE_SCRIPTORIUM/scripts/install-simplesuite.sh" \
    >"$TMP/install.log"

[ -x "$SIMPLESUITE_SYSTEM_BIN_DIR/simplewords" ]
[ -x "$SIMPLESUITE_SYSTEM_BIN_DIR/simplenet" ]
[ -x "$SIMPLESUITE_SYSTEM_BIN_DIR/simpleserve" ]
[ ! -e "$HOME/.local/bin/simpleserved" ]
[ -x "$SIMPLESUITE_SYSTEM_BIN_DIR/simplesuite-uninstall" ]
grep -q '^# frozen SimpleOS daemon$' "$SIMPLESERVE_DAEMON_BINARY"
[ -r "$HOME/.local/share/simplesuite/simplewords-typewriter.wav" ]
[ -r "$HOME/.local/share/simplesuite/simplewords-typewriter-NOTICE.md" ]
[ -r "$HOME/.local/share/simplesuite/install-source" ]
[ -r "$HOME/.local/share/simplesuite/install-manifest" ]
[ -r "$HOME/.local/share/simplesuite/command-abbreviations" ]
[ ! -e "$HOME/.local/bin/net" ]
[ ! -e "$HOME/.local/bin/serve" ]
[ ! -e "$HOME/.local/bin/suite-uninstall" ]
[ ! -e "$HOME/.local/bin/blue" ]
grep -q '^typewriter_sound=false$' "$HOME/.config/simplewords/config"
grep -q '^typewriter_sound_volume=70$' "$HOME/.config/simplewords/config"
[ -r "$HOME/.config/simplefiles/config" ]
[ -r "$HOME/.config/simplemail/config" ]
[ -r "$HOME/.config/simplenews/config.example" ]
[ -r "$HOME/.config/simplenews/urls.example" ]
[ -x "$HOME/system-libexec/simplefiles-freebsd-unmount" ]
[ -r "$HOME/simpleserve-system-verified" ]
grep -q '^yes$' "$HOME/package-install-ran"
grep -q '^client$' "$HOME/simpleserve-network-role"

HOME="$TMP/macos-home"
export HOME
mkdir -p "$HOME"

PATH="$FAKE_BIN:$REAL_GIT_DIR:/usr/local/bin:/usr/bin:/bin" \
FAKE_UNAME=Darwin \
FAKE_BREW_ROOT="$TMP/homebrew" \
SIMPLESUITE_REPO_URL="$FAKE_REPO" \
SIMPLESUITE_DIR="$HOME/simplesuite" \
SIMPLESUITE_INSTALL_REMINDERS=0 \
    "$FAKE_SCRIPTORIUM/scripts/install-simplesuite.sh" \
    >"$TMP/install-macos.log"

[ -x "$SIMPLESUITE_SYSTEM_BIN_DIR/simplewords" ]
[ -x "$SIMPLESUITE_SYSTEM_BIN_DIR/simplebrowse-webkitd" ]
[ -x "$SIMPLESUITE_SYSTEM_BIN_DIR/simpleserve" ]
[ ! -e "$HOME/.local/bin/simpleserved" ]
[ ! -e "$HOME/simpleserve-system-verified" ]
[ -r "$HOME/.local/share/simplesuite/install-source" ]
[ ! -e "$HOME/.local/bin/serve" ]
[ ! -e "$HOME/.local/bin/net" ]
[ ! -e "$HOME/.local/bin/blue" ]
grep -q '^yes$' "$HOME/package-install-ran"
grep -q '^yes$' "$HOME/macos-build-ran"
grep -q '^client$' "$HOME/simpleserve-network-role"

HOME="$TMP/linux-home"
export HOME
mkdir -p "$HOME/.local/bin"
printf '%s\n' stale >"$HOME/.local/bin/simpleblue"
printf '%s\n' unrelated >"$HOME/.local/bin/personal-tool"
chmod 755 "$HOME/.local/bin/simpleblue" "$HOME/.local/bin/personal-tool"

PATH="$FAKE_BIN:$REAL_GIT_DIR:/usr/local/bin:/usr/bin:/bin" \
FAKE_UNAME=Linux \
FAKE_BREW_ROOT="$TMP/homebrew" \
SIMPLESUITE_REPO_URL="$FAKE_REPO" \
SIMPLESUITE_DIR="$HOME/simplesuite" \
SIMPLESUITE_INSTALL_REMINDERS=0 \
FAKE_SERVICE_FAILURE=1 \
    "$FAKE_SCRIPTORIUM/scripts/install-simplesuite.sh" \
    >"$TMP/install-linux.log"

[ -x "$SIMPLESUITE_SYSTEM_BIN_DIR/simplewords" ]
[ -x "$SIMPLESUITE_SYSTEM_BIN_DIR/simpleblue" ]
[ ! -L "$SIMPLESUITE_SYSTEM_BIN_DIR/simpleblue" ]
cmp "$SIMPLESUITE_SYSTEM_BIN_DIR/simpleblue" "$HOME/simplesuite/build/simpleblue"
[ ! -e "$HOME/.local/bin/simpleblue" ]
[ "$(cat "$HOME/.local/bin/personal-tool")" = unrelated ]
[ -x "$SIMPLESUITE_SYSTEM_BIN_DIR/simpleserve" ]
[ ! -e "$HOME/.local/bin/simpleserved" ]
[ ! -e "$HOME/simpleserve-system-verified" ]
grep -q '^# frozen SimpleOS daemon$' "$SIMPLESERVE_DAEMON_BINARY"
[ ! -e "$HOME/package-install-ran" ]
[ ! -e "$HOME/.local/bin/blue" ]
[ ! -e "$HOME/.local/bin/net" ]
[ ! -e "$HOME/.local/bin/serve" ]
grep -q '^yes$' "$HOME/linux-build-ran"
grep -q '^client$' "$HOME/simpleserve-network-role"

HOME="$TMP/linux-client-home"
export HOME
mkdir -p "$HOME"

PATH="$FAKE_BIN:$REAL_GIT_DIR:/usr/local/bin:/usr/bin:/bin" \
FAKE_UNAME=Linux \
FAKE_BREW_ROOT="$TMP/homebrew" \
SIMPLESUITE_REPO_URL="$FAKE_REPO" \
SIMPLESUITE_DIR="$HOME/simplesuite" \
SIMPLESUITE_INSTALL_REMINDERS=0 \
SIMPLESUITE_NETWORK_ROLE=client \
    "$FAKE_SCRIPTORIUM/scripts/install-simplesuite.sh" \
    >"$TMP/install-linux-client.log"

[ -x "$SIMPLESUITE_SYSTEM_BIN_DIR/simpleserve" ]
[ ! -e "$HOME/.local/bin/simpleserved" ]
[ ! -e "$HOME/.local/bin/serve" ]
grep -q '^client$' "$HOME/simpleserve-network-role"
[ ! -e "$HOME/simpleserve-system-role-verified" ]

# Repeated application updates also preserve the daemon when it is unhealthy.
PATH="$FAKE_BIN:$REAL_GIT_DIR:/usr/local/bin:/usr/bin:/bin" \
FAKE_UNAME=Linux FAKE_SERVICE_FAILURE=1 \
SIMPLESUITE_REPO_URL="$FAKE_REPO" SIMPLESUITE_DIR="$HOME/simplesuite" \
SIMPLESUITE_INSTALL_REMINDERS=0 \
    "$FAKE_SCRIPTORIUM/scripts/install-simplesuite.sh" >"$TMP/reinstall.log"
[ ! -e "$HOME/simpleserve-system-verified" ]
grep -q '^# frozen SimpleOS daemon$' "$SIMPLESERVE_DAEMON_BINARY"

# An unavailable update source must reuse the clean checkout and keep its SHA.
offline_sha=$(git -C "$HOME/simplesuite" rev-parse HEAD)
git -C "$HOME/simplesuite" remote set-url origin "$TMP/unavailable-source"
PATH="$FAKE_BIN:$REAL_GIT_DIR:/usr/local/bin:/usr/bin:/bin" \
FAKE_UNAME=Linux SIMPLESUITE_DIR="$HOME/simplesuite" SIMPLESUITE_INSTALL_REMINDERS=0 \
    "$FAKE_SCRIPTORIUM/scripts/install-simplesuite.sh" >"$TMP/offline.log" 2>&1
grep -q 'building the existing local checkout' "$TMP/offline.log"
[ "$(git -C "$HOME/simplesuite" rev-parse HEAD)" = "$offline_sha" ]
git -C "$HOME/simplesuite" remote set-url origin "$FAKE_REPO"

# Explicit health verification still fails with the verifier's actual reason.
if PATH="$FAKE_BIN:$REAL_GIT_DIR:/usr/local/bin:/usr/bin:/bin" \
   FAKE_UNAME=Linux FAKE_SERVICE_FAILURE=1 \
   SIMPLESUITE_REPO_URL="$FAKE_REPO" SIMPLESUITE_DIR="$HOME/simplesuite" \
   SIMPLESUITE_INSTALL_REMINDERS=0 SIMPLESUITE_INSTALL_SIMPLESERVE_SYSTEM=require \
       "$FAKE_SCRIPTORIUM/scripts/install-simplesuite.sh" \
       >"$TMP/require-unhealthy.log" 2>&1; then
    echo 'install-simplesuite-check: required service verification was ignored' >&2
    exit 1
fi
grep -q 'fixture: existing daemon is not responding' "$TMP/require-unhealthy.log"

# Preservation still requires the installed daemon file.
mv "$SIMPLESERVE_DAEMON_BINARY" "$TMP/frozen-daemon"
if PATH="$FAKE_BIN:$REAL_GIT_DIR:/usr/local/bin:/usr/bin:/bin" \
   FAKE_UNAME=Linux \
   SIMPLESUITE_REPO_URL="$FAKE_REPO" SIMPLESUITE_DIR="$HOME/simplesuite" \
   SIMPLESUITE_INSTALL_REMINDERS=0 \
       "$FAKE_SCRIPTORIUM/scripts/install-simplesuite.sh" \
       >"$TMP/missing-daemon.log" 2>&1; then
    echo 'install-simplesuite-check: missing preserved daemon was accepted' >&2
    exit 1
fi
grep -q 'Preserved SimpleServe daemon is missing' "$TMP/missing-daemon.log"
mv "$TMP/frozen-daemon" "$SIMPLESERVE_DAEMON_BINARY"

HOME="$TMP/linux-without-simpleserve-home"
export HOME
mkdir -p "$HOME/.local/bin"
printf '%s\n' preserved-client >"$HOME/.local/bin/simpleserve"
printf '%s\n' preserved-daemon >"$HOME/.local/bin/simpleserved"
chmod 755 "$HOME/.local/bin/simpleserve" "$HOME/.local/bin/simpleserved"
printf '%s\n' preserved-system-service >"$HOME/simpleserve-system-verified"

PATH="$FAKE_BIN:$REAL_GIT_DIR:/usr/local/bin:/usr/bin:/bin" \
FAKE_UNAME=Linux \
FAKE_BREW_ROOT="$TMP/homebrew" \
SIMPLESUITE_REPO_URL="$FAKE_REPO" \
SIMPLESUITE_DIR="$HOME/simplesuite" \
SIMPLESUITE_INSTALL_REMINDERS=0 \
SIMPLESUITE_INSTALL_SIMPLESERVE=0 \
    "$FAKE_SCRIPTORIUM/scripts/install-simplesuite.sh" \
    >"$TMP/install-linux-without-simpleserve.log"

[ -x "$SIMPLESUITE_SYSTEM_BIN_DIR/simplewords" ]
[ -x "$SIMPLESUITE_SYSTEM_BIN_DIR/simpleblue" ]
grep -q '^preserved-client$' "$HOME/.local/bin/simpleserve"
[ ! -e "$HOME/.local/bin/simpleserved" ]
grep -q '^# frozen SimpleOS daemon$' "$SIMPLESERVE_DAEMON_BINARY"
grep -q '^preserved-system-service$' "$HOME/simpleserve-system-verified"
grep -q '^0$' "$HOME/simpleserve-component-selection"
grep -q '^none$' "$HOME/simpleserve-network-role"
[ ! -e "$HOME/.local/bin/blue" ]
[ ! -e "$HOME/.local/bin/net" ]
[ ! -e "$HOME/.local/bin/serve" ]

echo 'OK Scriptorium installs system binaries, preserves the daemon, and keeps explicit service verification'
