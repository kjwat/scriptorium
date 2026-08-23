#!/bin/sh
set -eu

SUITE=${SIMPLESUITE_DIR:-$HOME/simplesuite}
BINARY=${SIMPLESERVE_DAEMON_BINARY:-$HOME/.local/bin/simpleserved}
CLIENT=${SIMPLESERVE_CLIENT_BINARY:-$HOME/.local/bin/simpleserve}
VERIFY_ONLY=0

case "${1-}" in
    '') ;;
    --verify-only) VERIFY_ONLY=1 ;;
    *)
        echo "Usage: setup-network-client.sh [--verify-only]" >&2
        exit 2
        ;;
esac

[ -x "$BINARY" ] && [ -x "$CLIENT" ] || {
    echo "setup-server: SimpleServe client and daemon must already be installed." >&2
    echo "Run Scriptorium install.sh before changing this machine's role." >&2
    exit 1
}
[ -x "$SUITE/install-simpleserve-system.sh" ] &&
[ -x "$SUITE/verify-simpleserve-system.sh" ] &&
[ -f "$SUITE/init/simpleserve.client.role" ] || {
    echo "setup-server: $SUITE does not contain role-aware SimpleServe setup." >&2
    echo "Update Scriptorium and SimpleSuite, then rerun install.sh." >&2
    exit 1
}

verify_client() {
    SIMPLESUITE_NETWORK_ROLE=client \
        "$SUITE/verify-simpleserve-system.sh" "$BINARY" "$CLIENT"
}

if [ "$VERIFY_ONLY" -eq 1 ]; then
    verify_client
    printf 'Trident client role verified.\n'
    exit 0
fi

printf 'Changing this machine to Trident client (discover + mount only)...\n'
if [ "$(id -u)" -eq 0 ]; then
    SIMPLESUITE_NETWORK_ROLE=client \
        "$SUITE/install-simpleserve-system.sh" "$BINARY"
elif command -v sudo >/dev/null 2>&1; then
    sudo env SIMPLESUITE_NETWORK_ROLE=client \
        "$SUITE/install-simpleserve-system.sh" "$BINARY"
else
    echo "setup-server: root privileges are required, but sudo is unavailable." >&2
    exit 1
fi

verify_client
refresh=$("$CLIENT" refresh 2>&1) || {
    echo "setup-server: SimpleServe could not refresh its Tailscale routes:" >&2
    printf '%s\n' "$refresh" >&2
    exit 1
}
case "$refresh" in
    *'Tailscale: active ('*) ;;
    *)
        echo "setup-server: client mode requires an active Tailscale transport." >&2
        printf '%s\n' "$refresh" >&2
        exit 1
        ;;
esac
status=$("$CLIENT" status 2>/dev/null || true)
case "$status" in
    *'Role: client (mount only)'*) ;;
    *)
        echo "setup-server: the restarted daemon does not report client mode." >&2
        exit 1
        ;;
esac
printf 'Trident client role is active; remembered NFS mounts were preserved and Tailscale routes refreshed.\n'
