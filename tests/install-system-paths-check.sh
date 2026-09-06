#!/usr/bin/env bash
set -euo pipefail

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/scriptorium-system-paths.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
mkdir -p "$tmp/home/.local/bin" "$tmp/system/bin" "$tmp/system/sbin" "$tmp/suite"

for program in simplewords simplesuite-uninstall; do
    printf '%s\n' '#!/bin/sh' 'exit 0' >"$tmp/system/bin/$program"
done
for program in simplecheck setup-server; do
    printf '%s\n' '#!/bin/sh' 'exit 0' >"$tmp/home/.local/bin/$program"
done
cat >"$tmp/system/bin/simplecal" <<'EOF'
#!/bin/sh
[ "$1" = --install-reminders ] || exit 1
printf '%s\n' reminders >>"$TEST_CALL_LOG"
EOF
cat >"$tmp/system/bin/simpleserve" <<'EOF'
#!/bin/sh
printf '%s\n' unexpected-daemon-query >>"$TEST_CALL_LOG"
exit 1
EOF
printf '%s\n' '#!/bin/sh' '# frozen daemon' 'exit 99' \
    >"$tmp/system/sbin/simpleserved"
cat >"$tmp/suite/verify-simpleserve-system.sh" <<'EOF'
#!/bin/sh
set -eu
[ "$#" -eq 2 ]
[ "$1" = "$SIMPLESERVE_DAEMON_BINARY" ]
[ "$2" = "$SIMPLESUITE_SYSTEM_BIN_DIR/simpleserve" ]
[ -x "$1" ] && [ -x "$2" ]
printf '%s\n' verify >>"$TEST_CALL_LOG"
EOF
chmod 755 "$tmp/system/bin/"* "$tmp/system/sbin/"* \
    "$tmp/home/.local/bin/"* "$tmp/suite/verify-simpleserve-system.sh"

for verification_mode in preserve require; do
    HOME="$tmp/home" TEST_ROOT="$repo" TEST_CALL_LOG="$tmp/$verification_mode.calls" \
    SIMPLESUITE_SYSTEM_BIN_DIR="$tmp/system/bin" \
    SIMPLESERVE_DAEMON_BINARY="$tmp/system/sbin/simpleserved" \
    SIMPLESUITE_DIR="$tmp/suite" TEST_MODE="$verification_mode" \
        bash <<'EOF'
set -euo pipefail
ROOT=$TEST_ROOT
HOST_OS=Linux
SIMPLESUITE_INSTALL_SIMPLESERVE=1
SIMPLESUITE_NETWORK_ROLE=client
SCRIPTORIUM_INSTALL_TAILSCALE=1
CHANGES_MADE=0
SHELL_RC_FILES=("$HOME/.bashrc")
EXPECTED_SIMPLESUITE_COMMANDS=(simplewords simplecal simpleserve simpleserved simplecheck)
EXPECTED_SIMPLESUITE_HELPERS=(simplesuite-uninstall)
say() { :; }
warn() { printf '%s\n' "$*" >&2; }
scriptorium_program_aliases() {
    printf '%s\n' words:simplewords cal:simplecal serve:simpleserve check:simplecheck \
        absent:scriptorium_test_missing_program
}

# Exercise the actual install defaults, PATH, alias setup, and final checks.
if [[ $TEST_MODE == require ]]; then
    SIMPLESUITE_INSTALL_SIMPLESERVE_SYSTEM=require
    SCRIPTORIUM_INSTALL_TAILSCALE=0
else
    unset SIMPLESUITE_INSTALL_SIMPLESERVE_SYSTEM
fi
eval "$(awk '
    /^# The SimpleOS daemon/ { copying=1 }
    /^SIMPLESUITE_INSTALL_PACKAGES=0/ { exit }
    copying { print }
' "$ROOT/install.sh")"
[[ $simpleserve_service_mode == "$TEST_MODE" ]]
eval "$(awk '/^export PATH=.*SIMPLESUITE_SYSTEM_BIN_DIR/ { print }' "$ROOT/install.sh")"
eval "$(awk '
    /^ensure_simplesuite_aliases_in_file\(\)/ { copying=1 }
    /^remove_legacy_program_symlinks\(\)/ { exit }
    copying { print }
' "$ROOT/install.sh")"
ensure_simplesuite_aliases
for mapping in words:simplewords cal:simplecal serve:simpleserve check:simplecheck; do
    grep -qx "alias ${mapping%%:*}='${mapping#*:}'" "$HOME/.bashrc"
done
! grep -q 'alias absent=' "$HOME/.bashrc"
eval "$(awk '
    /^say "Verifying commands"/ { copying=1 }
    /^offer_server_promotion$/ { exit }
    copying { print }
' "$ROOT/install.sh")"
grep -qx reminders "$TEST_CALL_LOG"
! grep -q unexpected-daemon-query "$TEST_CALL_LOG"
if [[ $TEST_MODE == require ]]; then
    grep -qx verify "$TEST_CALL_LOG"
else
    ! grep -q verify "$TEST_CALL_LOG"
fi
[[ ! -e $HOME/.local/bin/simplewords ]]
[[ ! -e $HOME/.local/bin/simplecal ]]
[[ ! -e $HOME/.local/bin/simpleserve ]]
EOF
done

echo 'OK installer final checks and aliases use system binaries while preserving the existing daemon'
