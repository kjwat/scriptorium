#!/bin/sh
set -eu

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/setup-network-server-check.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

fixture=$tmp/scriptorium
suite=$tmp/simplesuite
fake_bin=$tmp/bin
daemon=$tmp/home/.local/bin/simpleserved
log=$tmp/calls.log
mkdir -p "$fixture/scripts" "$suite/init" "$fake_bin" "$(dirname "$daemon")"

cat >"$fixture/scripts/install-packages.sh" <<'EOF'
#!/bin/sh
set -eu
[ "${SIMPLESUITE_NETWORK_ROLE:-}" = server ]
[ "${SIMPLESUITE_INSTALL_SIMPLESERVE:-}" = 1 ]
[ "${SCRIPTORIUM_PACKAGES_SCOPE:-}" = network ]
printf 'packages\n' >>"$TRIDENT_TEST_LOG"
EOF

cat >"$suite/install-simpleserve-system.sh" <<'EOF'
#!/bin/sh
set -eu
[ "${SIMPLESUITE_NETWORK_ROLE:-}" = server ]
[ "$#" -eq 1 ] && [ -x "$1" ]
printf 'install\n' >>"$TRIDENT_TEST_LOG"
EOF

cat >"$suite/verify-simpleserve-system.sh" <<'EOF'
#!/bin/sh
set -eu
[ "${SIMPLESUITE_NETWORK_ROLE:-}" = server ]
[ "$#" -eq 1 ] && [ -x "$1" ]
printf 'verify\n' >>"$TRIDENT_TEST_LOG"
EOF

cat >"$fake_bin/sudo" <<'EOF'
#!/bin/sh
exec "$@"
EOF

printf '%s\n' '#!/bin/sh' 'exit 0' >"$daemon"
printf '%s\n' server >"$suite/init/simpleserve.server.role"
chmod 755 "$fixture/scripts/install-packages.sh" \
    "$suite/install-simpleserve-system.sh" \
    "$suite/verify-simpleserve-system.sh" "$fake_bin/sudo" "$daemon"

TRIDENT_TEST_LOG=$log PATH="$fake_bin:/usr/bin:/bin" \
SCRIPTORIUM_ROOT=$fixture SIMPLESUITE_DIR=$suite \
SIMPLESERVE_DAEMON_BINARY=$daemon \
    "$repo/scripts/setup-network-server.sh" >"$tmp/setup.out"

test "$(sed -n '1p' "$log")" = packages
test "$(sed -n '2p' "$log")" = install
test "$(sed -n '3p' "$log")" = verify
grep -q 'Trident server role is active' "$tmp/setup.out"

TRIDENT_TEST_LOG=$log PATH="$fake_bin:/usr/bin:/bin" \
SCRIPTORIUM_ROOT=$fixture SIMPLESUITE_DIR=$suite \
SIMPLESERVE_DAEMON_BINARY=$daemon \
    "$repo/scripts/setup-network-server.sh" --verify-only >"$tmp/verify.out"

test "$(wc -l <"$log")" -eq 4
test "$(sed -n '4p' "$log")" = verify
grep -q 'Trident server role verified' "$tmp/verify.out"

if TRIDENT_TEST_LOG=$log PATH="$fake_bin:/usr/bin:/bin" \
    SCRIPTORIUM_ROOT=$fixture SIMPLESUITE_DIR=$suite \
    SIMPLESERVE_DAEMON_BINARY=$tmp/missing \
    "$repo/scripts/setup-network-server.sh" >"$tmp/missing.out" 2>&1; then
    echo 'setup-network-server-check: missing daemon was accepted' >&2
    exit 1
fi

echo 'OK setup-server explicitly promotes and read-only verification does not mutate packages'
