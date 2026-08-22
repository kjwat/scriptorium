#!/usr/bin/env bash
set -euo pipefail

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/simpletrident-check.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT HUP INT TERM

HOME_DIR=$TEST_ROOT/home
FAKE_BIN=$TEST_ROOT/bin
WEBSITE=$HOME_DIR/website
ROLE_FILE=$TEST_ROOT/simpleserve-role
CADDY_FILE=$TEST_ROOT/Caddyfile
SIMPLESERVE_VERIFY=$TEST_ROOT/verify-simpleserve-system.sh
mkdir -p "$HOME_DIR/.local/bin" "$FAKE_BIN" "$WEBSITE/tools"
printf '%s\n' server >"$ROLE_FILE"
printf '%s\n' ':8080 { root * /tmp }' >"$CADDY_FILE"
cp "$CADDY_FILE" "$WEBSITE/tools/Caddyfile.production"

cat >"$FAKE_BIN/simpleserve" <<'EOF'
#!/bin/sh
[ "${1-}" = status ] || exit 2
if [ "${SIMPLETRIDENT_TEST_SCENARIO:-healthy}" = bad-simpleserve ]; then
    echo 'simpleserve: cannot reach simpleserved: connection refused' >&2
    exit 1
fi
cat <<STATUS
SIMPLESERVE STATUS

Server: test-host
Role: server (publish + mount)
Tailscale: $([ "${SIMPLETRIDENT_TEST_SCENARIO:-healthy}" = bad-tailscale ] && printf '%s' 'running, not authenticated' || printf '%s' 'active (100.70.80.90)')
STATUS
EOF

cat >"$FAKE_BIN/simpleserved" <<'EOF'
#!/bin/sh
exit 0
EOF

cat >"$FAKE_BIN/tailscale" <<'EOF'
#!/bin/sh
if [ "${1-}" = status ] && [ "${2-}" = --json ]; then
    if [ "${SIMPLETRIDENT_TEST_SCENARIO:-healthy}" = bad-tailscale ]; then
        echo '{"BackendState": "NeedsLogin"}'
    else
        echo '{"BackendState": "Running"}'
    fi
    exit 0
fi
if [ "${1-}" = ip ] && [ "${2-}" = -4 ]; then
    if [ "${SIMPLETRIDENT_TEST_SCENARIO:-healthy}" = bad-tailscale ]; then
        echo 'Logged out. Log in at the authentication URL.' >&2
        exit 1
    fi
    echo 100.70.80.90
    exit 0
fi
exit 2
EOF

cat >"$FAKE_BIN/systemctl" <<'EOF'
#!/bin/sh
if [ "${1-}" = show ] &&
   [ "${SIMPLETRIDENT_TEST_SCENARIO:-healthy}" = custom-site ]; then
    echo 'SITE_ROOT=/srv/test SITE_ADDRESS=:9090'
fi
exit 0
EOF

cat >"$SIMPLESERVE_VERIFY" <<'EOF'
#!/bin/sh
if [ "${SIMPLETRIDENT_TEST_SCENARIO:-healthy}" = bad-simpleserve-system ]; then
    echo 'SimpleServe runtime prerequisite commands are missing: avahi-browse' >&2
    exit 1
fi
echo 'Verified installed and running SimpleServe system service.'
EOF

cat >"$FAKE_BIN/caddy" <<'EOF'
#!/bin/sh
[ "${1-}" = validate ] || exit 2
if [ "${SIMPLETRIDENT_TEST_SCENARIO:-healthy}" = bad-website ]; then
    echo 'Error: adapting config: test syntax error' >&2
    exit 1
fi
echo 'Valid configuration'
EOF

cat >"$WEBSITE/tools/check_server.sh" <<'EOF'
#!/bin/sh
if [ "${SIMPLETRIDENT_TEST_SCENARIO:-healthy}" = custom-site ] &&
   [ "${CADDY_CHECK_ORIGIN:-}" != http://127.0.0.1:9090 ]; then
    echo "error: wrong custom origin: ${CADDY_CHECK_ORIGIN:-missing}" >&2
    exit 1
fi
if [ "${SIMPLETRIDENT_TEST_SCENARIO:-healthy}" = bad-website ]; then
    echo 'error: Caddy service is not active' >&2
    exit 1
fi
echo 'server verified: local Caddy origin and store are healthy'
EOF

chmod 755 "$FAKE_BIN"/* "$SIMPLESERVE_VERIFY" \
    "$WEBSITE/tools/check_server.sh"

HOME="$HOME_DIR" "$ROOT/scripts/install-simpletrident.sh" \
    >"$TEST_ROOT/install.out"
TRIDENT=$HOME_DIR/.local/bin/simpletrident
[ -x "$TRIDENT" ]
grep -q "Installed $TRIDENT" "$TEST_ROOT/install.out"

run_check() {
    scenario=$1
    output=$2
    set +e
    HOME="$HOME_DIR" \
    PATH="$FAKE_BIN:/usr/bin:/bin" \
    SIMPLETRIDENT_SERVICE_MANAGER=systemd \
    SIMPLETRIDENT_ROLE_FILE="$ROLE_FILE" \
    SIMPLETRIDENT_SIMPLESERVE_VERIFY="$SIMPLESERVE_VERIFY" \
    SIMPLETRIDENT_CADDYFILE="$CADDY_FILE" \
    SIMPLETRIDENT_WEBSITE_DIR="$WEBSITE" \
    SIMPLETRIDENT_TEST_SCENARIO="$scenario" \
        "$TRIDENT" --check >"$output" 2>&1
    check_status=$?
    set -e
}

run_check healthy "$TEST_ROOT/healthy.out"
[ "$check_status" -eq 0 ]
grep -q '^\[OK *\] SimpleServe / intranet$' "$TEST_ROOT/healthy.out"
grep -q '^\[OK *\] Tailscale / encrypted extranet$' "$TEST_ROOT/healthy.out"
grep -q '^\[OK *\] Caddy website / local web origin$' "$TEST_ROOT/healthy.out"
grep -q 'connected at 100.70.80.90; SimpleServe bridge is active' \
    "$TEST_ROOT/healthy.out"

run_check custom-site "$TEST_ROOT/custom-site.out"
[ "$check_status" -eq 0 ]
grep -q '^\[OK *\] Caddy website / local web origin$' \
    "$TEST_ROOT/custom-site.out"

run_check bad-tailscale "$TEST_ROOT/tailscale.out"
[ "$check_status" -eq 1 ]
grep -q '^\[PROBLEM\] Tailscale / encrypted extranet$' "$TEST_ROOT/tailscale.out"
grep -q 'Tailscale is not authenticated' "$TEST_ROOT/tailscale.out"
grep -q 'SimpleServe does not report an active Tailscale bridge' \
    "$TEST_ROOT/tailscale.out"
grep -q 'How to fix:' "$TEST_ROOT/tailscale.out"
grep -q 'scripts/setup-tailscale.sh' "$TEST_ROOT/tailscale.out"

run_check bad-website "$TEST_ROOT/website.out"
[ "$check_status" -eq 1 ]
grep -q '^\[PROBLEM\] Caddy website / local web origin$' "$TEST_ROOT/website.out"
grep -q 'The installed Caddy config is invalid' "$TEST_ROOT/website.out"
grep -q 'error: Caddy service is not active' "$TEST_ROOT/website.out"
grep -q 'setup-server --verify-only --no-public-check' "$TEST_ROOT/website.out"

run_check bad-simpleserve "$TEST_ROOT/simpleserve.out"
[ "$check_status" -eq 1 ]
grep -q '^\[PROBLEM\] SimpleServe / intranet$' "$TEST_ROOT/simpleserve.out"
grep -q 'The SimpleServe control socket is not responding' \
    "$TEST_ROOT/simpleserve.out"
grep -q 'The SimpleServe-to-Tailscale bridge could not be verified' \
    "$TEST_ROOT/simpleserve.out"

run_check bad-simpleserve-system "$TEST_ROOT/simpleserve-system.out"
[ "$check_status" -eq 1 ]
grep -q 'The SimpleServe system installation is incomplete or stale' \
    "$TEST_ROOT/simpleserve-system.out"
grep -q 'runtime prerequisite commands are missing: avahi-browse' \
    "$TEST_ROOT/simpleserve-system.out"

"$TRIDENT" --help | grep -q 'Usage: simpletrident'

echo 'OK simpletrident verifies all three prongs and supplies actionable failures'
