#!/bin/sh
set -eu

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/scriptorium-role-default.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
role_file=$tmp/simpleserve-role

resolve_default() (
    unset SIMPLESUITE_NETWORK_ROLE SIMPLESUITE_INSTALL_SIMPLESERVE \
        SIMPLESUITE_ROLE_FILE SIMPLESERVE_SYSTEM_ROOT
    SCRIPTORIUM_SIMPLESERVE_ROLE_FILE=$role_file
    export SCRIPTORIUM_SIMPLESERVE_ROLE_FILE
    . "$repo/scripts/resolve-simpleserve-role.sh"
    scriptorium_resolve_simpleserve_role
)

[ "$(resolve_default)" = client ]
printf '%s\n' client >"$role_file"
[ "$(resolve_default)" = client ]
printf '%s\n' server >"$role_file"
[ "$(resolve_default)" = server ]

(
    SIMPLESUITE_NETWORK_ROLE=server
    SIMPLESUITE_INSTALL_SIMPLESERVE=1
    export SIMPLESUITE_NETWORK_ROLE SIMPLESUITE_INSTALL_SIMPLESERVE
    . "$repo/scripts/resolve-simpleserve-role.sh"
    [ "$(scriptorium_resolve_simpleserve_role)" = server ]
)

(
    unset SIMPLESUITE_NETWORK_ROLE
    SIMPLESUITE_INSTALL_SIMPLESERVE=0
    export SIMPLESUITE_INSTALL_SIMPLESERVE
    . "$repo/scripts/resolve-simpleserve-role.sh"
    [ "$(scriptorium_resolve_simpleserve_role)" = none ]
)

if (
    SIMPLESUITE_NETWORK_ROLE=client
    SIMPLESUITE_INSTALL_SIMPLESERVE=0
    export SIMPLESUITE_NETWORK_ROLE SIMPLESUITE_INSTALL_SIMPLESERVE
    . "$repo/scripts/resolve-simpleserve-role.sh"
    scriptorium_resolve_simpleserve_role
) >"$tmp/conflict.out" 2>&1; then
    echo 'simpleserve-role-default-check: conflicting selection was accepted' >&2
    exit 1
fi
grep -q 'conflicts with SIMPLESUITE_INSTALL_SIMPLESERVE' "$tmp/conflict.out"

printf '%s\n' publisher >"$role_file"
if resolve_default >"$tmp/invalid.out" 2>&1; then
    echo 'simpleserve-role-default-check: invalid existing role was accepted' >&2
    exit 1
fi
grep -q 'must contain exactly client or server' "$tmp/invalid.out"

echo 'OK standalone Scriptorium installs default to client and preserve roles'
