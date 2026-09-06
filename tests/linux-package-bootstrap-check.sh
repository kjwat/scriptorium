#!/bin/sh
set -eu

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
BASH_BIN=$(command -v bash)
TEST_PKG_CONFIG=$(command -v pkg-config)
export TEST_PKG_CONFIG
tmp=$(mktemp -d "${TMPDIR:-/tmp}/scriptorium-linux-packages.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

fixture=$tmp/fixture
fake_bin=$tmp/bin
home=$tmp/home
apt_log=$tmp/apt.log
mkdir -p "$fixture/scripts" "$fake_bin/pkgconfig" "$home"
cp "$repo/scripts/install-packages.sh" \
    "$repo/scripts/resolve-simpleserve-role.sh" \
    "$repo/scripts/checkdeps.sh" "$fixture/scripts/"

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
        case " $* " in
            *' libnm-dev '*)
                if [ "${FAKE_APT_OMIT_LIBNM:-0}" != 1 ]; then
                    cat >"$FAKE_BIN/pkgconfig/libnm.pc" <<'PC'
Name: libnm
Description: NetworkManager client library fixture
Version: 1.52.1
PC
                fi
                ;;
        esac
        for runtime_command in less ntfsfix blkid avahi-daemon avahi-browse \
            avahi-publish-service exportfs mount.nfs mount.cifs smbd testparm \
            ssh sshd; do
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

cat >"$fake_bin/pkg-config" <<'EOF'
#!/bin/sh
case "$*" in
    *libnm*)
        PKG_CONFIG_PATH= PKG_CONFIG_LIBDIR="$FAKE_BIN/pkgconfig" \
            "$TEST_PKG_CONFIG" "$@"
        ;;
    *) exit 0 ;;
esac
EOF

for utility in awk bash cat chmod dirname env grep id mktemp rm tee; do
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
SCRIPTORIUM_SIMPLESERVE_ROLE_FILE="$tmp/no-existing-role" \
PATH="$fake_bin" \
    "$fixture/scripts/install-packages.sh" >"$tmp/install.log" 2>&1

grep -q '^install -y ' "$apt_log"
for package_name in \
    libnm-dev libavahi-client-dev nfs-common avahi-daemon avahi-utils cifs-utils \
    openssh-client openssh-server; do
    grep -Eq "^install -y .*(^|[[:space:]])${package_name}([[:space:]]|$)" \
        "$apt_log" || {
        echo "linux-package-bootstrap-check: apt transaction omitted $package_name" >&2
        exit 1
    }
done
if grep -Eq '(^|[[:space:]])(nfs-kernel-server|samba)([[:space:]]|$)' \
    "$apt_log"; then
    echo 'linux-package-bootstrap-check: fresh client installed publishing packages' >&2
    exit 1
fi
if grep -Eq '^install -y .*(^|[[:space:]])bluez([[:space:]]|$)' "$apt_log"; then
    echo "linux-package-bootstrap-check: apt transaction forced optional BlueZ" >&2
    exit 1
fi
[ ! -e "$fake_bin/bluetoothctl" ] || {
    echo "linux-package-bootstrap-check: optional bluetoothctl appeared unexpectedly" >&2
    exit 1
}
grep -q 'Package dependency installation verified' "$tmp/install.log"

: >"$apt_log"
HOME="$home" FAKE_APT_LOG="$apt_log" FAKE_BIN="$fake_bin" \
SCRIPTORIUM_SIMPLESERVE_ROLE_FILE="$tmp/no-existing-role" \
PATH="$fake_bin" \
    "$fixture/scripts/install-packages.sh" >"$tmp/recheck.log" 2>&1
[ ! -s "$apt_log" ] || {
    echo 'linux-package-bootstrap-check: complete runtime triggered another package transaction' >&2
    exit 1
}
grep -q 'Package dependencies already present' "$tmp/recheck.log"

# Use real pkg-config metadata so both a missing library and an old version
# must trigger repair, while the minimum supported version passes unchanged.
for libnm_version in missing 1.22 1.24; do
    if [ "$libnm_version" = missing ]; then
        rm -f "$fake_bin/pkgconfig/libnm.pc"
    else
        printf 'Name: libnm\nDescription: libnm fixture\nVersion: %s\n' \
            "$libnm_version" >"$fake_bin/pkgconfig/libnm.pc"
    fi
    check_status=0
    HOME="$home" FAKE_BIN="$fake_bin" PATH="$fake_bin" \
    SCRIPTORIUM_SIMPLESERVE_ROLE_FILE="$tmp/no-existing-role" \
        "$BASH_BIN" "$fixture/scripts/checkdeps.sh" \
        >"$tmp/libnm-check.log" 2>&1 || check_status=$?
    if [ "$libnm_version" = 1.24 ]; then
        [ "$check_status" -eq 0 ]
        grep -q 'All checked dependencies are present' "$tmp/libnm-check.log"
    else
        [ "$check_status" -eq 2 ]
        grep -q '^MISSING: NetworkManager client .*libnm >= 1.24.*libnm-dev' \
            "$tmp/libnm-check.log"
    fi

    : >"$apt_log"
    HOME="$home" FAKE_APT_LOG="$apt_log" FAKE_BIN="$fake_bin" \
    SCRIPTORIUM_SIMPLESERVE_ROLE_FILE="$tmp/no-existing-role" PATH="$fake_bin" \
        "$fixture/scripts/install-packages.sh" >"$tmp/libnm-install.log" 2>&1
    if [ "$libnm_version" = 1.24 ]; then
        [ ! -s "$apt_log" ]
    else
        grep -Eq '^install -y .* libnm-dev( |$)' "$apt_log"
        grep -q 'Package dependency installation verified' "$tmp/libnm-install.log"
    fi
done

# A successful package-manager exit is insufficient if libnm remains missing.
rm -f "$fake_bin/pkgconfig/libnm.pc"
install_status=0
HOME="$home" FAKE_APT_LOG="$apt_log" FAKE_BIN="$fake_bin" \
FAKE_APT_OMIT_LIBNM=1 PATH="$fake_bin" \
SCRIPTORIUM_SIMPLESERVE_ROLE_FILE="$tmp/no-existing-role" \
    "$fixture/scripts/install-packages.sh" >"$tmp/libnm-incomplete.log" 2>&1 \
    || install_status=$?
[ "$install_status" -eq 1 ]
grep -q 'expected dependencies are still unavailable' "$tmp/libnm-incomplete.log"
grep -q '^MISSING: NetworkManager client' "$tmp/libnm-incomplete.log"

# An explicit standalone build needs neither libnm headers nor their package.
HOME="$home" FAKE_BIN="$fake_bin" PATH="$fake_bin" SIMPLENET_WITH_NM=0 \
SCRIPTORIUM_SIMPLESERVE_ROLE_FILE="$tmp/no-existing-role" \
    "$BASH_BIN" "$fixture/scripts/checkdeps.sh" \
    >"$tmp/libnm-standalone-check.log" 2>&1
grep -q 'All checked dependencies are present' "$tmp/libnm-standalone-check.log"
: >"$apt_log"
HOME="$home" FAKE_APT_LOG="$apt_log" FAKE_BIN="$fake_bin" \
PATH="$fake_bin" SIMPLENET_WITH_NM=0 \
SCRIPTORIUM_SIMPLESERVE_ROLE_FILE="$tmp/no-existing-role" \
    "$fixture/scripts/install-packages.sh" >"$tmp/libnm-standalone-skip.log" 2>&1
[ ! -s "$apt_log" ]
rm -f "$fake_bin/less"
HOME="$home" FAKE_APT_LOG="$apt_log" FAKE_BIN="$fake_bin" \
PATH="$fake_bin" SIMPLENET_WITH_NM=0 \
SCRIPTORIUM_SIMPLESERVE_ROLE_FILE="$tmp/no-existing-role" \
    "$fixture/scripts/install-packages.sh" >"$tmp/libnm-standalone-install.log" 2>&1
grep -q '^install -y ' "$apt_log"
if grep -q 'libnm-dev' "$apt_log"; then
    echo 'linux-package-bootstrap-check: standalone build installed libnm headers' >&2
    exit 1
fi

rm -f "$fake_bin/ntfsfix"
: >"$apt_log"
HOME="$home" FAKE_APT_LOG="$apt_log" FAKE_BIN="$fake_bin" \
SCRIPTORIUM_SIMPLESERVE_ROLE_FILE="$tmp/no-existing-role" \
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
    "$fake_bin/testparm" "$fake_bin/ssh" "$fake_bin/sshd"
: >"$apt_log"
HOME="$tmp/without-simpleserve-home" FAKE_APT_LOG="$apt_log" \
FAKE_BIN="$fake_bin" PATH="$fake_bin" SIMPLESUITE_INSTALL_SIMPLESERVE=0 \
    "$fixture/scripts/install-packages.sh" \
    >"$tmp/install-without-simpleserve.log" 2>&1
grep -q '^install -y ' "$apt_log"
if grep -Eq 'libavahi-client-dev|nfs-kernel-server|nfs-common|avahi-daemon|avahi-utils|cifs-utils|openssh-client|openssh-server|samba' \
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
    libavahi-client-dev nfs-common avahi-daemon avahi-utils cifs-utils \
    openssh-client openssh-server; do
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
grep -Eq '^install -y .*openssh-client.*openssh-server' "$apt_log" || {
    echo 'linux-package-bootstrap-check: server promotion omitted OpenSSH programs' >&2
    exit 1
}
if grep -Eq 'build-essential|mpv|pandoc|isync|calcurse' "$apt_log"; then
    echo 'linux-package-bootstrap-check: server promotion reinstalled unrelated Scriptorium packages' >&2
    exit 1
fi
grep -q 'Trident server package installation verified' \
    "$tmp/install-promotion.log"

echo 'OK Scriptorium repairs libnm build dependencies and splits Trident packages'
