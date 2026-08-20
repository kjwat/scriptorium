#!/bin/sh
set -eu

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/scriptorium-arch-unattended.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

fixture=$tmp/fixture
fake_bin=$tmp/bin
home=$tmp/home
pacman_log=$tmp/pacman.log
sudo_log=$tmp/sudo.log
network_ready=$tmp/network-ready
mkdir -p "$fixture/scripts" "$fake_bin" "$home"
cp "$repo/scripts/install-packages.sh" "$fixture/scripts/install-packages.sh"

cat >"$fixture/scripts/detect-platform.sh" <<'EOF'
#!/bin/sh
printf '%s\n' arch
EOF

cat >"$fake_bin/id" <<'EOF'
#!/bin/sh
printf '%s\n' 1000
EOF

cat >"$fake_bin/pkg-config" <<'EOF'
#!/bin/sh
set -eu
[ "${1-}" = --exists ]
[ "${2-}" = avahi-client ]
[ -f "$FAKE_NETWORK_READY" ]
EOF

cat >"$fake_bin/pacman-conf" <<'EOF'
#!/bin/sh
case "${1-}" in
    --repo-list) printf '%s\n' core ;;
    --repo) printf '%s\n' 'https://mirror.example.invalid/$repo/os/$arch' ;;
    *) exit 2 ;;
esac
EOF

cat >"$fake_bin/sudo" <<'EOF'
#!/bin/sh
set -eu
printf '%s\n' "$*" >>"$FAKE_SUDO_LOG"
if [ "${1-}" = -n ]; then
    shift
fi
exec "$@"
EOF

cat >"$fake_bin/pacman" <<'EOF'
#!/bin/sh
set -eu
printf '%s\n' "$*" >>"$FAKE_PACMAN_LOG"
: >"$FAKE_NETWORK_READY"
EOF

for command_name in \
    avahi-daemon avahi-browse mount.nfs mount.cifs; do
    printf '%s\n' '#!/bin/sh' 'exit 0' >"$fake_bin/$command_name"
done

chmod 755 "$fixture/scripts"/* "$fake_bin"/*

HOME="$home" PATH="$fake_bin:/usr/bin:/bin" \
FAKE_NETWORK_READY="$network_ready" FAKE_PACMAN_LOG="$pacman_log" \
FAKE_SUDO_LOG="$sudo_log" SCRIPTORIUM_PACKAGES_SCOPE=network \
SCRIPTORIUM_NONINTERACTIVE=1 SIMPLESUITE_NETWORK_ROLE=client \
    "$fixture/scripts/install-packages.sh" >"$tmp/install.log" 2>&1

grep -q '^-Syu --needed --noconfirm nfs-utils avahi cifs-utils$' \
    "$pacman_log"
grep -q '^-n env LC_ALL=C pacman -Syu --needed --noconfirm ' \
    "$sudo_log"
grep -q 'Trident client package installation verified' "$tmp/install.log"

echo 'OK unattended Arch networking uses non-prompting pacman and sudo flags'
