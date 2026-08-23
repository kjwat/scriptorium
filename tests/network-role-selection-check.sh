#!/usr/bin/env bash
set -euo pipefail

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/network-role-selection.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
mkdir -p "$tmp/scriptorium/scripts" "$tmp/home" "$tmp/empty-bin"

cat >"$tmp/scriptorium/scripts/detect-platform.sh" <<'EOF'
#!/bin/sh
printf '%s\n' debian
EOF
chmod 755 "$tmp/scriptorium/scripts/detect-platform.sh"

# Exercise the actual selection functions without running the rest of install.sh.
eval "$(awk '
    /^say\(\)/ { copying=1 }
    /^run_as_root\(\)/ { exit }
    copying { print }
' "$repo/install.sh")"

fresh_case() (
    unset SCRIPTORIUM_NETWORK_ROLE SIMPLESUITE_NETWORK_ROLE \
        SIMPLESUITE_INSTALL_SIMPLESERVE SCRIPTORIUM_INSTALL_TAILSCALE
    ROOT=$tmp/scriptorium
    HOME=$tmp/home
    HOST_OS=Linux
    PATH=$tmp/empty-bin:/usr/bin:/bin
    SCRIPTORIUM_SIMPLESERVE_ROLE_FILE=$tmp/no-role
    SCRIPTORIUM_LEGACY_SIMPLESERVE_DAEMON=$tmp/no-daemon
    export ROOT HOME HOST_OS PATH SCRIPTORIUM_SIMPLESERVE_ROLE_FILE \
        SCRIPTORIUM_LEGACY_SIMPLESERVE_DAEMON

    choose_network_role <<<'' >"$tmp/fresh.out"
    choose_tailscale_component >>"$tmp/fresh.out"
    [[ $SCRIPTORIUM_NETWORK_ROLE == client ]]
    [[ $SIMPLESUITE_NETWORK_ROLE == client ]]
    [[ $SIMPLESUITE_INSTALL_SIMPLESERVE == 1 ]]
    [[ $SCRIPTORIUM_INSTALL_TAILSCALE == 1 ]]
    grep -q "Join Keelan's Networking Trident? \[Y/n\]" "$tmp/fresh.out"
    ! grep -q 'Install and connect Tailscale' "$tmp/fresh.out"
)

existing_server_case() (
    unset SCRIPTORIUM_NETWORK_ROLE SIMPLESUITE_NETWORK_ROLE \
        SIMPLESUITE_INSTALL_SIMPLESERVE SCRIPTORIUM_INSTALL_TAILSCALE
    printf '%s\n' server >"$tmp/existing-role"
    ROOT=$tmp/scriptorium
    HOME=$tmp/home
    HOST_OS=Linux
    PATH=$tmp/empty-bin:/usr/bin:/bin
    SCRIPTORIUM_SIMPLESERVE_ROLE_FILE=$tmp/existing-role
    SCRIPTORIUM_LEGACY_SIMPLESERVE_DAEMON=$tmp/no-daemon
    export ROOT HOME HOST_OS PATH SCRIPTORIUM_SIMPLESERVE_ROLE_FILE \
        SCRIPTORIUM_LEGACY_SIMPLESERVE_DAEMON

    choose_network_role </dev/null >"$tmp/existing.out"
    choose_tailscale_component >>"$tmp/existing.out"
    [[ $SCRIPTORIUM_NETWORK_ROLE == server ]]
    [[ $SIMPLESUITE_INSTALL_SIMPLESERVE == 1 ]]
    grep -q 'Preserving existing Trident role: server' "$tmp/existing.out"
    ! grep -q "Join Keelan's Networking Trident" "$tmp/existing.out"
)

disabled_case() (
    unset SIMPLESUITE_NETWORK_ROLE SIMPLESUITE_INSTALL_SIMPLESERVE \
        SCRIPTORIUM_INSTALL_TAILSCALE
    ROOT=$tmp/scriptorium
    HOME=$tmp/home
    HOST_OS=Linux
    PATH=$tmp/empty-bin:/usr/bin:/bin
    SCRIPTORIUM_NETWORK_ROLE=none
    export ROOT HOME HOST_OS PATH SCRIPTORIUM_NETWORK_ROLE

    choose_network_role >"$tmp/disabled.out"
    choose_tailscale_component >>"$tmp/disabled.out"
    [[ $SIMPLESUITE_NETWORK_ROLE == none ]]
    [[ $SIMPLESUITE_INSTALL_SIMPLESERVE == 0 ]]
    [[ $SCRIPTORIUM_INSTALL_TAILSCALE == 0 ]]
)

client_without_tailscale_case() (
    unset SIMPLESUITE_NETWORK_ROLE SIMPLESUITE_INSTALL_SIMPLESERVE
    ROOT=$tmp/scriptorium
    HOME=$tmp/home
    HOST_OS=Linux
    PATH=$tmp/empty-bin:/usr/bin:/bin
    SCRIPTORIUM_NETWORK_ROLE=client
    SCRIPTORIUM_INSTALL_TAILSCALE=0
    export ROOT HOME HOST_OS PATH SCRIPTORIUM_NETWORK_ROLE \
        SCRIPTORIUM_INSTALL_TAILSCALE

    choose_network_role >"$tmp/client-no-tail.out"
    choose_tailscale_component >>"$tmp/client-no-tail.out"
    [[ $SIMPLESUITE_NETWORK_ROLE == client ]]
    [[ $SCRIPTORIUM_INSTALL_TAILSCALE == 0 ]]
)

unattended_without_role_case() (
    unset SCRIPTORIUM_NETWORK_ROLE SIMPLESUITE_NETWORK_ROLE \
        SIMPLESUITE_INSTALL_SIMPLESERVE SCRIPTORIUM_INSTALL_TAILSCALE
    ROOT=$tmp/scriptorium
    HOME=$tmp/home
    HOST_OS=Linux
    PATH=$tmp/empty-bin:/usr/bin:/bin
    SCRIPTORIUM_NONINTERACTIVE=1
    SCRIPTORIUM_SIMPLESERVE_ROLE_FILE=$tmp/no-role
    SCRIPTORIUM_LEGACY_SIMPLESERVE_DAEMON=$tmp/no-daemon
    export ROOT HOME HOST_OS PATH SCRIPTORIUM_NONINTERACTIVE \
        SCRIPTORIUM_SIMPLESERVE_ROLE_FILE SCRIPTORIUM_LEGACY_SIMPLESERVE_DAEMON

    set +e
    ( choose_network_role </dev/null >"$tmp/unattended.out" 2>&1 )
    status=$?
    set -e
    [[ $status -eq 2 ]]
    grep -q 'unattended install needs SCRIPTORIUM_NETWORK_ROLE' \
        "$tmp/unattended.out"
    ! grep -q "Join Keelan's Networking Trident" "$tmp/unattended.out"
)

server_promotion_offer_case() (
    mkdir -p "$tmp/promotion-home/.local/bin"
    cat >"$tmp/promotion-home/.local/bin/setup-server" <<'EOF'
#!/bin/sh
printf '%s\n' called >"$HOME/setup-server-called"
EOF
    chmod 755 "$tmp/promotion-home/.local/bin/setup-server"

    HOME=$tmp/promotion-home
    SCRIPTORIUM_NETWORK_ROLE=client
    SIMPLESUITE_NETWORK_ROLE=client
    SCRIPTORIUM_NONINTERACTIVE=0
    export HOME SCRIPTORIUM_NETWORK_ROLE SIMPLESUITE_NETWORK_ROLE \
        SCRIPTORIUM_NONINTERACTIVE

    offer_server_promotion <<<'yes' >"$tmp/promotion.out"
    [[ $SCRIPTORIUM_NETWORK_ROLE == server ]]
    [[ $SIMPLESUITE_NETWORK_ROLE == server ]]
    [[ -f $HOME/setup-server-called ]]
    grep -q 'full Trident server now' "$tmp/promotion.out"
    grep -q 'Full Trident server promotion completed' "$tmp/promotion.out"
)

unattended_client_offer_case() (
    HOME=$tmp/promotion-home
    rm -f "$HOME/setup-server-called"
    SCRIPTORIUM_NETWORK_ROLE=client
    SIMPLESUITE_NETWORK_ROLE=client
    SCRIPTORIUM_NONINTERACTIVE=1
    export HOME SCRIPTORIUM_NETWORK_ROLE SIMPLESUITE_NETWORK_ROLE \
        SCRIPTORIUM_NONINTERACTIVE

    offer_server_promotion >"$tmp/unattended-promotion.out"
    [[ $SCRIPTORIUM_NETWORK_ROLE == client ]]
    [[ ! -e $HOME/setup-server-called ]]
    grep -q 'Run setup-server to perform the full server promotion later' \
        "$tmp/unattended-promotion.out"
)

fresh_case
existing_server_case
disabled_case
client_without_tailscale_case
unattended_without_role_case
server_promotion_offer_case
unattended_client_offer_case

echo 'OK Trident selection handles client setup, full server promotion, preserved roles, and unattended installs'
