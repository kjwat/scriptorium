#!/bin/sh
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
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
        for runtime_command in blkid avahi-daemon avahi-browse \
            avahi-publish-service exportfs mount.nfs; do
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
    nfs-kernel-server nfs-common avahi-daemon avahi-utils; do
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

package_block() {
    family_name=$1
    awk -v family_name="$family_name" '
        $0 ~ "^    " family_name "\\)" {
            capture = 1
            block = ""
            has_install = 0
        }
        capture {
            block = block $0 "\n"
            if ($0 ~ /run_package_command/)
                has_install = 1
        }
        capture && /;;[[:space:]]*$/ {
            if (has_install) {
                printf "%s", block
                exit
            }
            capture = 0
        }
    ' "$repo/scripts/install-packages.sh"
}

assert_family_packages() {
    family_name=$1
    shift
    block=$(package_block "$family_name")
    [ -n "$block" ] || {
        echo "linux-package-bootstrap-check: no install block for $family_name" >&2
        exit 1
    }
    for package_name in "$@"; do
        printf '%s\n' "$block" |
            grep -Eq "(^|[[:space:]])${package_name}([[:space:]]|$)" || {
            echo "linux-package-bootstrap-check: $family_name omitted $package_name" >&2
            exit 1
        }
    done
}

assert_family_packages debian nfs-kernel-server nfs-common avahi-daemon avahi-utils
assert_family_packages void nfs-utils avahi
assert_family_packages arch nfs-utils avahi
assert_family_packages alpine nfs-utils nfs-utils-openrc avahi avahi-openrc avahi-tools
assert_family_packages fedora nfs-utils avahi avahi-tools
assert_family_packages suse nfs-kernel-server nfs-client avahi avahi-utils
assert_family_packages freebsd avahi-app

echo 'OK Scriptorium installs and verifies SimpleServe runtime packages on supported Unix platforms'
