#!/bin/sh
set -eu

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/demote-server-check.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

home=$tmp/home
root=$tmp/root
fake_bin=$tmp/bin
log=$tmp/calls.log
mkdir -p "$home/website/tools" "$home/.config/keelanwatlington" \
    "$root/etc/systemd/system/caddy.service.d" "$root/run/systemd/system" \
    "$root/etc/cloudflared" "$fake_bin"
printf '%s\n' server >"$root/etc/simpleserve-role"
printf '%s\n' secret >"$home/.config/keelanwatlington/store.env"
printf '%s\n' token >"$root/etc/cloudflared/keelanwatlington.token"
for file in keelanwatlington-store.service keelanwatlington-blog-sync.service \
            keelanwatlington-blog-sync.timer; do
    printf '%s\n' managed >"$root/etc/systemd/system/$file"
done
printf '%s\n' managed >"$root/etc/systemd/system/caddy.service.d/website.conf"

cat >"$home/website/tools/backup_server_state.py" <<'EOF'
#!/bin/sh
set -eu
destination=$1
mkdir -m 700 "$destination"
cp "$HOME/.config/keelanwatlington/store.env" "$destination/store.env"
chmod 600 "$destination/store.env"
EOF
cat >"$home/setup-network-client" <<'EOF'
#!/bin/sh
printf '%s\n' network-client >>"$TRIDENT_TEST_LOG"
printf '%s\n' client >"$SCRIPTORIUM_SYSTEM_ROOT/etc/simpleserve-role"
EOF
cat >"$fake_bin/sudo" <<'EOF'
#!/bin/sh
exec "$@"
EOF
cat >"$fake_bin/systemctl" <<'EOF'
#!/bin/sh
case "$1" in
    is-active | is-enabled) exit 0 ;;
esac
printf 'systemctl %s\n' "$*" >>"$TRIDENT_TEST_LOG"
EOF
chmod 755 "$home/website/tools/backup_server_state.py" \
    "$home/setup-network-client" "$fake_bin/sudo" "$fake_bin/systemctl"

HOME=$home PATH="$fake_bin:/usr/bin:/bin" TRIDENT_TEST_LOG=$log \
SCRIPTORIUM_ROOT=$repo SCRIPTORIUM_SYSTEM_ROOT=$root \
SCRIPTORIUM_NETWORK_CLIENT_SETUP=$home/setup-network-client \
SCRIPTORIUM_SERVER_BACKUP_DIR=$home/backups WEBSITE_SERVICE_MANAGER=systemd \
    "$repo/scripts/demote-server.sh" >"$tmp/demote.out"

grep -q '^network-client$' "$log"
grep -q 'systemctl stop caddy.service' "$log"
grep -q 'systemctl disable cloudflared.service' "$log"
grep -q 'systemctl stop nfs-server.service' "$log"
grep -q 'systemctl disable smbd.service' "$log"
grep -q 'systemctl daemon-reload' "$log"
test "$(cat "$root/etc/simpleserve-role")" = client
test ! -e "$root/etc/systemd/system/keelanwatlington-store.service"
test ! -e "$root/etc/systemd/system/caddy.service.d/website.conf"
backup=$(find "$home/backups" -mindepth 1 -maxdepth 1 -type d -print -quit)
test -n "$backup"
test "$(cat "$backup/store.env")" = secret
test "$(cat "$backup/cloudflared/token")" = token
grep -q 'server options were removed; this machine is now a client' \
    "$tmp/demote.out"

echo 'OK server demotion backs up private state, disables web services, and restores client mode'
