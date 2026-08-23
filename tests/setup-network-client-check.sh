#!/bin/sh
set -eu

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/setup-network-client-check.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

suite=$tmp/simplesuite
fake_bin=$tmp/bin
daemon=$tmp/home/.local/bin/simpleserved
client=$tmp/home/.local/bin/simpleserve
log=$tmp/calls.log
mkdir -p "$suite/init" "$fake_bin" "$(dirname "$daemon")"

cat >"$suite/install-simpleserve-system.sh" <<'EOF'
#!/bin/sh
set -eu
[ "${SIMPLESUITE_NETWORK_ROLE:-}" = client ]
[ "$#" -eq 1 ] && [ -x "$1" ]
printf 'install\n' >>"$TRIDENT_TEST_LOG"
EOF

cat >"$suite/verify-simpleserve-system.sh" <<'EOF'
#!/bin/sh
set -eu
[ "${SIMPLESUITE_NETWORK_ROLE:-}" = client ]
[ "$#" -eq 2 ] && [ -x "$1" ] && [ -x "$2" ]
printf 'verify\n' >>"$TRIDENT_TEST_LOG"
EOF

cat >"$client" <<'EOF'
#!/bin/sh
case "${1-}" in
    refresh)
        printf 'refresh\n' >>"$TRIDENT_TEST_LOG"
        printf '%s\n' \
            'SimpleServe configured.' \
            'Role: client (mount only)' \
            'Tailscale: active (100.70.80.90)'
        ;;
    status) printf '%s\n' 'Role: client (mount only)' ;;
    *) exit 2 ;;
esac
EOF
cat >"$fake_bin/sudo" <<'EOF'
#!/bin/sh
exec "$@"
EOF
printf '%s\n' '#!/bin/sh' 'exit 0' >"$daemon"
printf '%s\n' client >"$suite/init/simpleserve.client.role"
chmod 755 "$suite/install-simpleserve-system.sh" \
    "$suite/verify-simpleserve-system.sh" "$fake_bin/sudo" "$daemon" "$client"

TRIDENT_TEST_LOG=$log PATH="$fake_bin:/usr/bin:/bin" \
SIMPLESUITE_DIR=$suite SIMPLESERVE_DAEMON_BINARY=$daemon \
SIMPLESERVE_CLIENT_BINARY=$client \
    "$repo/scripts/setup-network-client.sh" >"$tmp/setup.out"

test "$(sed -n '1p' "$log")" = install
test "$(sed -n '2p' "$log")" = verify
test "$(sed -n '3p' "$log")" = refresh
grep -q 'remembered NFS mounts were preserved and Tailscale routes refreshed' \
    "$tmp/setup.out"

TRIDENT_TEST_LOG=$log PATH="$fake_bin:/usr/bin:/bin" \
SIMPLESUITE_DIR=$suite SIMPLESERVE_DAEMON_BINARY=$daemon \
SIMPLESERVE_CLIENT_BINARY=$client \
    "$repo/scripts/setup-network-client.sh" --verify-only >"$tmp/verify.out"
test "$(sed -n '4p' "$log")" = verify
grep -q 'Trident client role verified' "$tmp/verify.out"

echo 'OK client setup changes role safely, preserves mounts, and verifies the daemon'
