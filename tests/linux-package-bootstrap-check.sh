#!/bin/sh
set -eu

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/scriptorium-linux-packages.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

fixture=$tmp/fixture
fake_bin=$tmp/bin
home=$tmp/home
apt_log=$tmp/apt.log
mkdir -p "$fixture/scripts" "$fake_bin" "$home"
cp "$repo/scripts/install-packages.sh" "$fixture/scripts/install-packages.sh"

cat >"$fixture/scripts/detect-platform.sh" <<'EOF'
#!/bin/sh
printf '%s\n' debian
EOF
chmod 755 "$fixture/scripts/detect-platform.sh"

cat >"$fake_bin/uname" <<'EOF'
#!/bin/sh
printf '%s\n' Linux
EOF

cat >"$fake_bin/sudo" <<'EOF'
#!/bin/sh
exec "$@"
EOF

cat >"$fake_bin/apt-get" <<'EOF'
#!/bin/sh
set -eu

case "${1-}" in
    indextargets)
        printf '%s\n' fake-Packages
        ;;
    update)
        printf '%s\n' update >>"$FAKE_APT_LOG"
        ;;
    install)
        printf '%s\n' "$*" >>"$FAKE_APT_LOG"
        for runtime_command in less ntfsfix blkid avahi-daemon avahi-browse \
            avahi-publish-service exportfs mount.nfs mount.cifs smbd testparm; do
            printf '%s\n' '#!/bin/sh' 'exit 0' >"$FAKE_BIN/$runtime_command"
            chmod 755 "$FAKE_BIN/$runtime_command"
        done
        ;;
    *)
        echo "unexpected apt-get arguments: $*" >&2
        exit 2
        ;;
esac
EOF

for dependency_command in \
    cc pkg-config git mpv pdftotext pandoc zip unzip tar file less fzf links \
    mbsync msmtp calcurse curl rsync make nano crontab python3 xdg-open gio \
    findmnt udisksctl e2fsck fsck.fat fsck.exfat ntfsfix wl-copy wl-paste \
    pactl parec xclip; do
    printf '%s\n' '#!/bin/sh' 'exit 0' >"$fake_bin/$dependency_command"
done

for utility in awk chmod dirname env grep id mktemp rm tee; do
    ln -s "$(command -v "$utility")" "$fake_bin/$utility"
done
chmod 755 "$fake_bin/uname" "$fake_bin/sudo" "$fake_bin/apt-get"
for dependency_command in \
    cc pkg-config git mpv pdftotext pandoc zip unzip tar file less fzf links \
    mbsync msmtp calcurse curl rsync make nano crontab python3 xdg-open gio \
    findmnt udisksctl e2fsck fsck.fat fsck.exfat ntfsfix wl-copy wl-paste \
    pactl parec xclip; do
    chmod 755 "$fake_bin/$dependency_command"
done

HOME="$home" FAKE_APT_LOG="$apt_log" FAKE_BIN="$fake_bin" \
PATH="$fake_bin" \
    "$fixture/scripts/install-packages.sh" >"$tmp/install.log" 2>&1

grep -q '^install -y ' "$apt_log"
for package_name in \
    libavahi-client-dev nfs-kernel-server nfs-common avahi-daemon avahi-utils \
    cifs-utils samba; do
    grep -Eq "^install -y .*(^|[[:space:]])${package_name}([[:space:]]|$)" \
        "$apt_log" || {
        echo "linux-package-bootstrap-check: apt transaction omitted $package_name" >&2
        exit 1
    }
done
grep -q 'Package dependency installation verified' "$tmp/install.log"

: >"$apt_log"
HOME="$home" FAKE_APT_LOG="$apt_log" FAKE_BIN="$fake_bin" \
PATH="$fake_bin" \
    "$fixture/scripts/install-packages.sh" >"$tmp/recheck.log" 2>&1
[ ! -s "$apt_log" ] || {
    echo 'linux-package-bootstrap-check: complete runtime triggered another package transaction' >&2
    exit 1
}
grep -q 'Package dependencies already present' "$tmp/recheck.log"

rm -f "$fake_bin/ntfsfix"
: >"$apt_log"
HOME="$home" FAKE_APT_LOG="$apt_log" FAKE_BIN="$fake_bin" \
PATH="$fake_bin" \
    "$fixture/scripts/install-packages.sh" >"$tmp/ntfs-repair.log" 2>&1
grep -Eq '^install -y .*ntfs-3g' "$apt_log" || {
    echo 'linux-package-bootstrap-check: missing ntfsfix did not trigger ntfs-3g install' >&2
    exit 1
}
grep -q 'Package dependency installation verified' "$tmp/ntfs-repair.log"

rm -f "$fake_bin/less" "$fake_bin/blkid" "$fake_bin/avahi-daemon" \
    "$fake_bin/avahi-browse" "$fake_bin/avahi-publish-service" \
    "$fake_bin/exportfs" "$fake_bin/mount.nfs" "$fake_bin/mount.cifs" "$fake_bin/smbd" \
    "$fake_bin/testparm"
: >"$apt_log"
HOME="$tmp/without-simpleserve-home" FAKE_APT_LOG="$apt_log" \
FAKE_BIN="$fake_bin" PATH="$fake_bin" SIMPLESUITE_INSTALL_SIMPLESERVE=0 \
    "$fixture/scripts/install-packages.sh" \
    >"$tmp/install-without-simpleserve.log" 2>&1
grep -q '^install -y ' "$apt_log"
if grep -Eq 'libavahi-client-dev|nfs-kernel-server|nfs-common|avahi-daemon|avahi-utils|cifs-utils|samba' \
    "$apt_log"; then
    echo 'linux-package-bootstrap-check: disabled SimpleServe packages were installed' >&2
    exit 1
fi
grep -q 'Package dependency installation verified' \
    "$tmp/install-without-simpleserve.log"

rm -f "$fake_bin/blkid" "$fake_bin/avahi-daemon" \
    "$fake_bin/avahi-browse" "$fake_bin/avahi-publish-service" \
    "$fake_bin/exportfs" "$fake_bin/mount.nfs" "$fake_bin/mount.cifs" \
    "$fake_bin/smbd" "$fake_bin/testparm"
: >"$apt_log"
HOME="$tmp/client-home" FAKE_APT_LOG="$apt_log" FAKE_BIN="$fake_bin" \
PATH="$fake_bin" SIMPLESUITE_NETWORK_ROLE=client \
    "$fixture/scripts/install-packages.sh" >"$tmp/install-client.log" 2>&1
for package_name in \
    libavahi-client-dev nfs-common avahi-daemon avahi-utils cifs-utils; do
    grep -Eq "^install -y .*(^|[[:space:]])${package_name}([[:space:]]|$)" \
        "$apt_log" || {
        echo "linux-package-bootstrap-check: client transaction omitted $package_name" >&2
        exit 1
    }
done
if grep -Eq 'nfs-kernel-server|samba' "$apt_log"; then
    echo 'linux-package-bootstrap-check: client role installed server packages' >&2
    exit 1
fi

rm -f "$fake_bin/blkid" "$fake_bin/avahi-daemon" \
    "$fake_bin/avahi-browse" "$fake_bin/avahi-publish-service" \
    "$fake_bin/exportfs" "$fake_bin/mount.nfs" "$fake_bin/mount.cifs" \
    "$fake_bin/smbd" "$fake_bin/testparm"
: >"$apt_log"
HOME="$tmp/promotion-home" FAKE_APT_LOG="$apt_log" FAKE_BIN="$fake_bin" \
PATH="$fake_bin" SIMPLESUITE_NETWORK_ROLE=server \
SCRIPTORIUM_PACKAGES_SCOPE=network \
    "$fixture/scripts/install-packages.sh" >"$tmp/install-promotion.log" 2>&1
grep -Eq '^install -y .*nfs-kernel-server.*samba' "$apt_log" || {
    echo 'linux-package-bootstrap-check: server promotion omitted publishing packages' >&2
    exit 1
}
if grep -Eq 'build-essential|mpv|pandoc|isync|calcurse' "$apt_log"; then
    echo 'linux-package-bootstrap-check: server promotion reinstalled unrelated Scriptorium packages' >&2
    exit 1
fi
grep -q 'Trident server package installation verified' \
    "$tmp/install-promotion.log"

echo 'OK Scriptorium splits client, server, and disabled Trident packages'
