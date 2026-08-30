#!/usr/bin/env bash
set -euo pipefail

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/simpletrident-check.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT HUP INT TERM

HOME_DIR=$TEST_ROOT/home
FAKE_BIN=$TEST_ROOT/bin
WEBSITE=$HOME_DIR/website
SERVER_ROOT=$HOME_DIR/scriptorium/scripts/server
ROLE_FILE=$TEST_ROOT/simpleserve-role
CADDY_FILE=$TEST_ROOT/Caddyfile
STORE_ENV=$HOME_DIR/.config/keelanwatlington/store.env
SIMPLESERVE_VERIFY=$TEST_ROOT/verify-simpleserve-system.sh
EXPORTS_FILE=$TEST_ROOT/simpleserve.exports
mkdir -p "$HOME_DIR/.local/bin" "$HOME_DIR/.config/keelanwatlington" \
    "$FAKE_BIN" "$WEBSITE/tools" "$SERVER_ROOT"
printf '%s\n' server >"$ROLE_FILE"
printf '%s\n' ':8080 { root * /tmp }' >"$CADDY_FILE"
cp "$CADDY_FILE" "$SERVER_ROOT/Caddyfile.production"

cat >"$FAKE_BIN/simpleserve" <<'EOF'
#!/bin/sh
[ "${1-}" = status ] || exit 2
if [ "${SIMPLETRIDENT_TEST_SCENARIO:-healthy}" = bad-simpleserve ]; then
    echo 'simpleserve: cannot reach simpleserved: connection refused' >&2
    exit 1
fi
configured_role=server
if [ -r "${SIMPLETRIDENT_ROLE_FILE:-}" ]; then
    IFS= read -r configured_role <"$SIMPLETRIDENT_ROLE_FILE"
fi
case "$configured_role" in
    client) role_status='client (mount only)' ;;
    *) role_status='server (publish + mount)' ;;
esac
case "${SIMPLETRIDENT_TEST_SCENARIO:-healthy}" in
    bad-tailscale) tailscale_status='running, not authenticated' ;;
    bridge-inactive) tailscale_status='inactive' ;;
    *) tailscale_status='active (100.70.80.90)' ;;
esac
if [ "$configured_role" = client ]; then
    local_shares='  (none)'
    case "${SIMPLETRIDENT_TEST_SCENARIO:-healthy}" in
        client-unmounted)
            managed_mounts='  test-server:Archive -> /tmp/Archive  not mounted, remembered, route: Tailscale, address: 100.70.80.91, Tailscale NFS: ready (100.70.80.91)'
            ;;
        client-tail-unreachable)
            managed_mounts='  test-server:Library -> /tmp/Library  mounted, remembered, route: LAN, address: 192.0.2.10, Tailscale NFS: unreachable (100.70.80.91)
  test-server:Archive -> /tmp/Archive  mounted, remembered, route: LAN, address: 192.0.2.10, Tailscale NFS: unreachable (100.70.80.91)'
            ;;
        client-no-tail-route)
            managed_mounts='  test-server:Library -> /tmp/Library  mounted, remembered, route: LAN, address: 192.0.2.10, Tailscale NFS: not configured
  test-server:Archive -> /tmp/Archive  mounted, remembered, route: LAN, address: 192.0.2.10, Tailscale NFS: not configured'
            ;;
        client-old-daemon)
            managed_mounts='  test-server:Library -> /tmp/Library  mounted, remembered, route: LAN, address: 192.0.2.10
  test-server:Archive -> /tmp/Archive  mounted, remembered, route: LAN, address: 192.0.2.10'
            ;;
        *)
            managed_mounts='  test-server:Library -> /tmp/Library  mounted, remembered, route: LAN, address: 192.0.2.10, Tailscale NFS: ready (100.70.80.91)
  test-server:Archive -> /tmp/Archive  mounted, remembered, route: Tailscale, address: 100.70.80.91, Tailscale NFS: ready (100.70.80.91)'
            ;;
    esac
else
    managed_mounts='  (none)'
    case "${SIMPLETRIDENT_TEST_SCENARIO:-healthy}" in
        server-no-shares) local_shares='  (none)' ;;
        server-share-unavailable)
            local_shares='  Archive  /media/test/Archive (drive unavailable)'
            ;;
        *) local_shares='  Library  /media/test/Library' ;;
    esac
fi
cat <<STATUS
SIMPLESERVE STATUS

Server: test-host
Role: $role_status
Tailscale: $tailscale_status

Local shares:
$local_shares

Managed mounts:
$managed_mounts
STATUS
EOF

cat >"$FAKE_BIN/simpleserved" <<'EOF'
#!/bin/sh
exit 0
EOF

cat >"$FAKE_BIN/ssh" <<'EOF'
#!/bin/sh
exit 0
EOF

cat >"$FAKE_BIN/sshd" <<'EOF'
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
if [ "${SIMPLETRIDENT_TEST_SCENARIO:-healthy}" = packaged-verifier ]; then
    printf '%s\n' ran >"$SIMPLETRIDENT_TEST_VERIFIER_MARKER"
fi
if [ "${SIMPLETRIDENT_TEST_SCENARIO:-healthy}" = bad-simpleserve-system ]; then
    echo 'SimpleServe runtime prerequisite commands are missing: avahi-browse' >&2
    exit 1
fi
echo 'Verified installed and running SimpleServe system service.'
EOF

cat >"$FAKE_BIN/caddy" <<'EOF'
#!/bin/sh
[ "${1-}" = validate ] || exit 2
case "${SIMPLETRIDENT_TEST_SCENARIO:-healthy}" in
    client | client-no-caddy | client-unmounted | client-tail-unreachable | client-no-tail-route | client-old-daemon)
        echo 'error: a server-only Caddy check ran in client mode' >&2
        exit 1
        ;;
esac
if [ "${SIMPLETRIDENT_TEST_SCENARIO:-healthy}" = bad-website ]; then
    echo 'Error: adapting config: test syntax error' >&2
    exit 1
fi
echo 'Valid configuration'
EOF

cat >"$SERVER_ROOT/check_server.sh" <<'EOF'
#!/bin/sh
if [ "${SIMPLETRIDENT_TEST_SCENARIO:-healthy}" = missing-source-config ]; then
    printf '%s\n' ran >"$SIMPLETRIDENT_TEST_HEALTH_MARKER"
fi
case "${SIMPLETRIDENT_TEST_SCENARIO:-healthy}" in
    missing-caddy)
        echo 'error: the Caddy-dependent health checker should have been blocked' >&2
        exit 1
        ;;
    client | client-no-caddy | client-unmounted | client-tail-unreachable | client-no-tail-route | client-old-daemon)
        echo 'error: the server website health checker ran in client mode' >&2
        exit 1
        ;;
esac
if [ "${SIMPLETRIDENT_TEST_SCENARIO:-healthy}" = custom-site ] &&
   [ "${CADDY_CHECK_ORIGIN:-}" != http://127.0.0.1:9090 ]; then
    echo "error: wrong custom origin: ${CADDY_CHECK_ORIGIN:-missing}" >&2
    exit 1
fi
if [ "${SIMPLETRIDENT_TEST_SCENARIO:-healthy}" = bad-website ]; then
    echo 'error: Caddy service is not active' >&2
    exit 1
fi
if [ "${SIMPLETRIDENT_TEST_SCENARIO:-healthy}" = bad-web-support ] &&
   { [ "${CHECK_BLOG_TIMER:-0}" = 1 ] ||
     [ "${CHECK_CLOUDFLARED:-0}" = 1 ]; }; then
    echo 'error: Cloudflare tunnel service is not active' >&2
    exit 1
fi
echo 'server verified: local Caddy origin and store are healthy'
EOF

chmod 755 "$FAKE_BIN"/* "$SIMPLESERVE_VERIFY" \
    "$SERVER_ROOT/check_server.sh"

HOME="$HOME_DIR" "$ROOT/scripts/install-simpletrident.sh" \
    >"$TEST_ROOT/install.out"
TRIDENT=$HOME_DIR/.local/bin/simpletrident
TRIDENT_ALIAS=$HOME_DIR/.local/bin/trident
[ -x "$TRIDENT" ]
[ ! -e "$TRIDENT_ALIAS" ]
grep -q "Installed $TRIDENT" "$TEST_ROOT/install.out"

run_check() {
    scenario=$1
    output=$2
    verifier_command=$SIMPLESERVE_VERIFY
    system_root=
    case "$scenario" in
        client | client-no-caddy | client-unmounted | client-tail-unreachable | client-no-tail-route | client-old-daemon)
            printf '%s\n' client >"$ROLE_FILE"
            ;;
        unknown-role) rm -f "$ROLE_FILE" ;;
        *) printf '%s\n' server >"$ROLE_FILE" ;;
    esac
    if [ "$scenario" = missing-source-config ]; then
        rm -f "$SERVER_ROOT/Caddyfile.production"
    else
        cp "$CADDY_FILE" "$SERVER_ROOT/Caddyfile.production"
    fi
    if [ "$scenario" = packaged-verifier ]; then
        packaged_suite=$TEST_ROOT/system/usr/local/share/simplesuite/source
        mkdir -p "$packaged_suite"
        cp "$SIMPLESERVE_VERIFY" \
            "$packaged_suite/verify-simpleserve-system.sh"
        verifier_command=
        system_root=$TEST_ROOT/system
    fi
    caddy_command=$FAKE_BIN/caddy
    if [ "$scenario" = missing-caddy ] || [ "$scenario" = client-no-caddy ]; then
        caddy_command=$TEST_ROOT/missing-caddy
    fi
    ssh_command=$FAKE_BIN/ssh
    sshd_command=$FAKE_BIN/sshd
    if [ "$scenario" = missing-ssh ]; then
        ssh_command=$TEST_ROOT/missing-ssh
    elif [ "$scenario" = missing-sshd ]; then
        sshd_command=$TEST_ROOT/missing-sshd
    fi
    if [ "$scenario" = server-no-recovery ]; then
        printf '%s\n' 'STRIPE_WEBHOOK_SECRETS=whsec_fixture' >"$STORE_ENV"
    else
        printf '%s\n' \
            'STRIPE_WEBHOOK_SECRETS=whsec_fixture' \
            'STORE_SMTP_HOST=smtp.example.com' \
            'STORE_EMAIL_FROM=Dionysia Publishing <books@example.com>' \
            >"$STORE_ENV"
    fi
    if [ "$scenario" = server-phone-incompatible ]; then
        printf '%s\n' \
            '/media/test/Library 192.0.2.0/24(rw,sync,no_subtree_check,all_squash,anonuid=1000,anongid=1000)' \
            '/media/test/Library 100.64.0.0/10(rw,sync,no_subtree_check,all_squash,anonuid=1000,anongid=1000)' \
            >"$EXPORTS_FILE"
    else
        printf '%s\n' \
            '/media/test/Library 192.0.2.0/24(rw,sync,no_subtree_check,insecure,all_squash,anonuid=1000,anongid=1000)' \
            '/media/test/Library 100.64.0.0/10(rw,sync,no_subtree_check,insecure,all_squash,anonuid=1000,anongid=1000)' \
            >"$EXPORTS_FILE"
    fi
    set +e
    HOME="$HOME_DIR" \
    PATH="$FAKE_BIN:/usr/bin:/bin" \
    SIMPLETRIDENT_SERVICE_MANAGER=systemd \
    SIMPLETRIDENT_SYSTEM_ROOT="$system_root" \
    SIMPLETRIDENT_ROLE_FILE="$ROLE_FILE" \
    SIMPLETRIDENT_SIMPLESERVE_VERIFY="$verifier_command" \
    SIMPLETRIDENT_EXPORTS="$EXPORTS_FILE" \
    SIMPLETRIDENT_SSH="$ssh_command" \
    SIMPLETRIDENT_SSHD="$sshd_command" \
    SIMPLETRIDENT_CADDY="$caddy_command" \
    SIMPLETRIDENT_CADDYFILE="$CADDY_FILE" \
    SIMPLETRIDENT_STORE_ENV="$STORE_ENV" \
    SIMPLETRIDENT_WEBSITE_DIR="$WEBSITE" \
    SIMPLETRIDENT_TEST_SCENARIO="$scenario" \
    SIMPLETRIDENT_TEST_HEALTH_MARKER="$TEST_ROOT/health-check-ran" \
    SIMPLETRIDENT_TEST_VERIFIER_MARKER="$TEST_ROOT/verifier-ran" \
        "$TRIDENT" --check >"$output" 2>&1
    check_status=$?
    set -e
}

run_check healthy "$TEST_ROOT/healthy.out"
[ "$check_status" -eq 0 ]
grep -q '^Mode: SERVER$' "$TEST_ROOT/healthy.out"
grep -q '^\[OK *\] SimpleServe / intranet$' "$TEST_ROOT/healthy.out"
grep -q '^\[OK *\] Tailscale / encrypted extranet$' "$TEST_ROOT/healthy.out"
grep -q '^\[OK *\] OpenSSH / client + daemon$' "$TEST_ROOT/healthy.out"
grep -q '^\[OK *\] Caddy website / local web origin$' "$TEST_ROOT/healthy.out"
[ "$(grep -c '^\[' "$TEST_ROOT/healthy.out")" -eq 4 ]
grep -q 'server role; 1 NFS/SMB share active; service ready' \
    "$TEST_ROOT/healthy.out"
grep -q 'connected at 100.70.80.90; NFS/SMB publishing bridge is active' \
    "$TEST_ROOT/healthy.out"
grep -q '^          Caddy, fulfillment mail, blog sync, and tunnel are healthy$' \
    "$TEST_ROOT/healthy.out"

run_check missing-source-config "$TEST_ROOT/missing-source-config.out"
[ "$check_status" -eq 0 ]
grep -q '^Mode: SERVER$' "$TEST_ROOT/missing-source-config.out"
grep -q '^\[OK *\] Caddy website / local web origin$' \
    "$TEST_ROOT/missing-source-config.out"
[ "$(cat "$TEST_ROOT/health-check-ran")" = ran ]
! grep -q "production Caddy source config is missing" \
    "$TEST_ROOT/missing-source-config.out"

run_check packaged-verifier "$TEST_ROOT/packaged-verifier.out"
[ "$check_status" -eq 0 ]
grep -q '^\[OK *\] SimpleServe / intranet$' \
    "$TEST_ROOT/packaged-verifier.out"
[ "$(cat "$TEST_ROOT/verifier-ran")" = ran ]

run_check server-no-recovery "$TEST_ROOT/server-no-recovery.out"
[ "$check_status" -eq 1 ]
grep -q '^Mode: SERVER$' "$TEST_ROOT/server-no-recovery.out"
grep -q '^\[PARTIAL\] Caddy website / local web origin$' \
    "$TEST_ROOT/server-no-recovery.out"
grep -q '^          Purchase-recovery email is not configured$' \
    "$TEST_ROOT/server-no-recovery.out"
grep -q '\[ok\] Paid-order recording and signed browser downloads remain available' \
    "$TEST_ROOT/server-no-recovery.out"
grep -q "documented STORE_SMTP_\* and STORE_EMAIL_\* settings" \
    "$TEST_ROOT/server-no-recovery.out"

run_check client "$TEST_ROOT/client.out"
[ "$check_status" -eq 0 ]
grep -q '^Mode: CLIENT$' "$TEST_ROOT/client.out"
grep -q '^\[OK *\] SimpleServe / intranet$' "$TEST_ROOT/client.out"
grep -q 'client role; 2 managed NFS mounts active' "$TEST_ROOT/client.out"
grep -q 'connected at 100.70.80.90; 2 NFS fallbacks ready' \
    "$TEST_ROOT/client.out"
grep -q '^\[OK *\] OpenSSH / client + daemon$' "$TEST_ROOT/client.out"
! grep -q 'Caddy website / local web origin' "$TEST_ROOT/client.out"
[ "$(grep -c '^\[' "$TEST_ROOT/client.out")" -eq 3 ]
! grep -q 'server-only Caddy check ran' "$TEST_ROOT/client.out"
! grep -q 'server website health checker ran' "$TEST_ROOT/client.out"

run_check client-no-caddy "$TEST_ROOT/client-no-caddy.out"
[ "$check_status" -eq 0 ]
grep -q '^Mode: CLIENT$' "$TEST_ROOT/client-no-caddy.out"
! grep -q 'Caddy website / local web origin' \
    "$TEST_ROOT/client-no-caddy.out"
! grep -qi 'Caddy is not installed' "$TEST_ROOT/client-no-caddy.out"

run_check unknown-role "$TEST_ROOT/unknown-role.out"
[ "$check_status" -eq 1 ]
grep -q '^Mode: UNKNOWN$' "$TEST_ROOT/unknown-role.out"
grep -q '^\[UNKNOWN\] SimpleServe / intranet$' "$TEST_ROOT/unknown-role.out"
grep -q '\[unknown\] The SimpleServe role file is missing or unreadable' \
    "$TEST_ROOT/unknown-role.out"
grep -q '\[ok\] The daemon control socket answered successfully' \
    "$TEST_ROOT/unknown-role.out"
grep -q '\[blocked\] Running daemon role check requires a valid configured role' \
    "$TEST_ROOT/unknown-role.out"
grep -q '^\[UNKNOWN\] Caddy website / local web origin$' \
    "$TEST_ROOT/unknown-role.out"
grep -q '\[blocked\] Caddy and website checks require a reliable SimpleServe mode' \
    "$TEST_ROOT/unknown-role.out"

run_check client-unmounted "$TEST_ROOT/client-unmounted.out"
[ "$check_status" -eq 1 ]
grep -q '^Mode: CLIENT$' "$TEST_ROOT/client-unmounted.out"
grep -q '^\[PARTIAL\] SimpleServe / intranet$' \
    "$TEST_ROOT/client-unmounted.out"
grep -q '\[partial\] 1 managed NFS mount is currently not mounted' \
    "$TEST_ROOT/client-unmounted.out"
grep -q 'simpleserve mount SERVER:SHARE --remember' \
    "$TEST_ROOT/client-unmounted.out"
! grep -q 'Caddy website / local web origin' \
    "$TEST_ROOT/client-unmounted.out"

run_check client-tail-unreachable "$TEST_ROOT/client-tail-unreachable.out"
[ "$check_status" -eq 1 ]
grep -q '^Mode: CLIENT$' "$TEST_ROOT/client-tail-unreachable.out"
grep -q '^\[DOWN *\] Tailscale / encrypted extranet$' \
    "$TEST_ROOT/client-tail-unreachable.out"
grep -q 'No remembered NFS mount is reachable over Tailscale' \
    "$TEST_ROOT/client-tail-unreachable.out"
grep -q '\[ok\] Tailscale backend state is Running' \
    "$TEST_ROOT/client-tail-unreachable.out"

run_check client-no-tail-route "$TEST_ROOT/client-no-tail-route.out"
[ "$check_status" -eq 1 ]
grep -q '^\[DOWN *\] Tailscale / encrypted extranet$' \
    "$TEST_ROOT/client-no-tail-route.out"
grep -q 'No remembered NFS mount is reachable over Tailscale' \
    "$TEST_ROOT/client-no-tail-route.out"

run_check client-old-daemon "$TEST_ROOT/client-old-daemon.out"
[ "$check_status" -eq 1 ]
grep -q '^\[UNKNOWN\] Tailscale / encrypted extranet$' \
    "$TEST_ROOT/client-old-daemon.out"
grep -q 'Tailscale NFS readiness is missing for 2 remembered mounts' \
    "$TEST_ROOT/client-old-daemon.out"

for client_output in \
    "$TEST_ROOT/client.out" \
    "$TEST_ROOT/client-no-caddy.out" \
    "$TEST_ROOT/client-unmounted.out" \
    "$TEST_ROOT/client-tail-unreachable.out" \
    "$TEST_ROOT/client-no-tail-route.out" \
    "$TEST_ROOT/client-old-daemon.out"
do
    ! grep -q 'Caddy website / local web origin' "$client_output"
    grep -q '^\[OK *\] OpenSSH / client + daemon$' "$client_output"
    [ "$(grep -c '^\[' "$client_output")" -eq 3 ]
done

run_check server-no-shares "$TEST_ROOT/server-no-shares.out"
[ "$check_status" -eq 1 ]
grep -q '^Mode: SERVER$' "$TEST_ROOT/server-no-shares.out"
grep -q '^\[PARTIAL\] SimpleServe / intranet$' \
    "$TEST_ROOT/server-no-shares.out"
grep -q '\[partial\] Server mode is ready, but no local shares are configured' \
    "$TEST_ROOT/server-no-shares.out"
grep -q 'simpleserve share /mounted/path --name NAME' \
    "$TEST_ROOT/server-no-shares.out"

run_check server-share-unavailable "$TEST_ROOT/server-share-unavailable.out"
[ "$check_status" -eq 1 ]
grep -q '^Mode: SERVER$' "$TEST_ROOT/server-share-unavailable.out"
grep -q '^\[DOWN *\] SimpleServe / intranet$' \
    "$TEST_ROOT/server-share-unavailable.out"
grep -q '\[down\] All 1 configured local share is unavailable' \
    "$TEST_ROOT/server-share-unavailable.out"
grep -q 'Reconnect the drive with the UUID originally registered for the share' \
    "$TEST_ROOT/server-share-unavailable.out"

run_check server-phone-incompatible "$TEST_ROOT/server-phone-incompatible.out"
[ "$check_status" -eq 1 ]
grep -q '^Mode: SERVER$' "$TEST_ROOT/server-phone-incompatible.out"
grep -q '^\[PARTIAL\] SimpleServe / intranet$' \
    "$TEST_ROOT/server-phone-incompatible.out"
grep -q '^          2 of 2 managed NFS export entries do not accept phone source ports$' \
    "$TEST_ROOT/server-phone-incompatible.out"
grep -q '\[partial\] 2 of 2 managed NFS export entries do not accept phone source ports' \
    "$TEST_ROOT/server-phone-incompatible.out"

run_check bridge-inactive "$TEST_ROOT/partial.out"
[ "$check_status" -eq 1 ]
grep -q '^\[PARTIAL\] Tailscale / encrypted extranet$' \
    "$TEST_ROOT/partial.out"
grep -q '\[ok\] Tailscale backend state is Running' "$TEST_ROOT/partial.out"
grep -q '\[ok\] Tailnet address is 100.70.80.90' "$TEST_ROOT/partial.out"
grep -q '\[partial\] SimpleServe does not report an active Tailscale bridge' \
    "$TEST_ROOT/partial.out"
grep -q 'Tailscale itself is connected. Reconcile the SimpleServe bridge' \
    "$TEST_ROOT/partial.out"
! grep -q 'Reinstall or reconnect the Trident' "$TEST_ROOT/partial.out"

run_check custom-site "$TEST_ROOT/custom-site.out"
[ "$check_status" -eq 0 ]
grep -q '^\[OK *\] Caddy website / local web origin$' \
    "$TEST_ROOT/custom-site.out"

run_check bad-tailscale "$TEST_ROOT/tailscale.out"
[ "$check_status" -eq 1 ]
grep -q '^\[DOWN *\] Tailscale / encrypted extranet$' "$TEST_ROOT/tailscale.out"
grep -q 'Tailscale is not authenticated' "$TEST_ROOT/tailscale.out"
grep -q '\[blocked\] Tailnet address check requires a running Tailscale backend' \
    "$TEST_ROOT/tailscale.out"
grep -q '\[blocked\] SimpleServe bridge check requires a usable tailnet connection' \
    "$TEST_ROOT/tailscale.out"
grep -q 'How to fix:' "$TEST_ROOT/tailscale.out"
grep -q 'scripts/setup-tailscale.sh' "$TEST_ROOT/tailscale.out"

run_check bad-website "$TEST_ROOT/website.out"
[ "$check_status" -eq 1 ]
grep -q '^\[DOWN *\] Caddy website / local web origin$' "$TEST_ROOT/website.out"
grep -q 'The installed Caddy config is invalid' "$TEST_ROOT/website.out"
grep -q 'error: Caddy service is not active' "$TEST_ROOT/website.out"
grep -q 'setup-server --verify-only --no-public-check' "$TEST_ROOT/website.out"
grep -q "$SERVER_ROOT/check_server.sh" "$TEST_ROOT/website.out"
! grep -q "$WEBSITE/tools/check_server.sh" "$TEST_ROOT/website.out"

run_check bad-web-support "$TEST_ROOT/website-support.out"
[ "$check_status" -eq 1 ]
grep -q '^\[PARTIAL\] Caddy website / local web origin$' \
    "$TEST_ROOT/website-support.out"
grep -q 'The local web origin works, but a supporting website service failed' \
    "$TEST_ROOT/website-support.out"
grep -q 'error: Cloudflare tunnel service is not active' \
    "$TEST_ROOT/website-support.out"
grep -q '\[ok\] Caddy, private-path rules, and store health still pass locally' \
    "$TEST_ROOT/website-support.out"

run_check bad-simpleserve "$TEST_ROOT/simpleserve.out"
[ "$check_status" -eq 1 ]
grep -q '^\[DOWN *\] SimpleServe / intranet$' "$TEST_ROOT/simpleserve.out"
grep -q 'The SimpleServe control socket is not responding' \
    "$TEST_ROOT/simpleserve.out"
grep -q '^\[UNKNOWN\] Tailscale / encrypted extranet$' \
    "$TEST_ROOT/simpleserve.out"
grep -q '\[blocked\] SimpleServe bridge check requires a working SimpleServe control socket' \
    "$TEST_ROOT/simpleserve.out"
grep -q 'Tailscale itself is connected. Reconcile the SimpleServe bridge' \
    "$TEST_ROOT/simpleserve.out"
! grep -q 'Reinstall or reconnect the Trident' "$TEST_ROOT/simpleserve.out"

run_check bad-simpleserve-system "$TEST_ROOT/simpleserve-system.out"
[ "$check_status" -eq 1 ]
grep -q 'The SimpleServe system installation is incomplete or stale' \
    "$TEST_ROOT/simpleserve-system.out"
grep -q 'runtime prerequisite commands are missing: avahi-browse' \
    "$TEST_ROOT/simpleserve-system.out"

run_check missing-caddy "$TEST_ROOT/missing-caddy.out"
[ "$check_status" -eq 1 ]
grep -q '^\[DOWN *\] Caddy website / local web origin$' \
    "$TEST_ROOT/missing-caddy.out"
grep -q '^          Caddy is not installed$' "$TEST_ROOT/missing-caddy.out"
grep -q '\[down\] Caddy is not installed' "$TEST_ROOT/missing-caddy.out"
grep -q '\[blocked\] Local website health check requires Caddy' \
    "$TEST_ROOT/missing-caddy.out"
! grep -q 'The local Caddy website health check failed' \
    "$TEST_ROOT/missing-caddy.out"
! grep -q 'Caddy-dependent health checker should have been blocked' \
    "$TEST_ROOT/missing-caddy.out"

run_check missing-ssh "$TEST_ROOT/missing-ssh.out"
[ "$check_status" -eq 1 ]
grep -q '^\[DOWN *\] OpenSSH / client + daemon$' \
    "$TEST_ROOT/missing-ssh.out"
grep -q '^          The OpenSSH client is not installed$' \
    "$TEST_ROOT/missing-ssh.out"
grep -q '\[ok\] OpenSSH daemon is installed at' "$TEST_ROOT/missing-ssh.out"
grep -q 'cd ~/scriptorium && ./install.sh' "$TEST_ROOT/missing-ssh.out"

run_check missing-sshd "$TEST_ROOT/missing-sshd.out"
[ "$check_status" -eq 1 ]
grep -q '^\[DOWN *\] OpenSSH / client + daemon$' \
    "$TEST_ROOT/missing-sshd.out"
grep -q '^          The OpenSSH daemon is not installed$' \
    "$TEST_ROOT/missing-sshd.out"
grep -q '\[ok\] OpenSSH client is installed at' "$TEST_ROOT/missing-sshd.out"

! grep -q '\[PROBLEM\]' "$TEST_ROOT"/*.out

"$TRIDENT" --help | grep -q 'Usage: simpletrident'

echo 'OK simpletrident reports modes, severity states, blocked checks, and actionable failures'
