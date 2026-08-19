#!/bin/sh
set -eu

ROOT=${SCRIPTORIUM_ROOT:-$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)}
SUITE=${SIMPLESUITE_DIR:-$HOME/simplesuite}
BINARY=${SIMPLESERVE_DAEMON_BINARY:-$HOME/.local/bin/simpleserved}
VERIFY_ONLY=0

case "${1-}" in
    '') ;;
    --verify-only) VERIFY_ONLY=1 ;;
    *)
        echo "Usage: setup-network-server.sh [--verify-only]" >&2
        exit 2
        ;;
esac

[ -x "$BINARY" ] || {
    echo "setup-server: SimpleServe is not installed at $BINARY." >&2
    echo "Run Scriptorium install.sh and join the Trident before setup-server." >&2
    exit 1
}
[ -x "$SUITE/install-simpleserve-system.sh" ] &&
[ -x "$SUITE/verify-simpleserve-system.sh" ] &&
[ -f "$SUITE/init/simpleserve.server.role" ] || {
    echo "setup-server: $SUITE does not contain role-aware SimpleServe setup." >&2
    echo "Update Scriptorium and SimpleSuite, then rerun install.sh." >&2
    exit 1
}

verify_server() {
    SIMPLESUITE_NETWORK_ROLE=server \
        "$SUITE/verify-simpleserve-system.sh" "$BINARY"
}

if [ "$VERIFY_ONLY" -eq 1 ]; then
    verify_server
    printf 'Trident server role verified.\n'
    exit 0
fi

printf 'Promoting this machine to Trident server (publish + mount)...\n'
SIMPLESUITE_NETWORK_ROLE=server SIMPLESUITE_INSTALL_SIMPLESERVE=1 \
    SCRIPTORIUM_PACKAGES_SCOPE=network \
    "$ROOT/scripts/install-packages.sh"

if [ "$(id -u)" -eq 0 ]; then
    SIMPLESUITE_NETWORK_ROLE=server \
        "$SUITE/install-simpleserve-system.sh" "$BINARY"
elif command -v sudo >/dev/null 2>&1; then
    sudo env SIMPLESUITE_NETWORK_ROLE=server \
        "$SUITE/install-simpleserve-system.sh" "$BINARY"
else
    echo "setup-server: root privileges are required, but sudo is unavailable." >&2
    exit 1
fi

verify_server
printf 'Trident server role is active.\n'
