#!/bin/sh
set -eu

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/scriptorium-freebsd-packages.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

fixture=$tmp/fixture
fake_bin=$tmp/bin
home=$tmp/home
pkg_log=$tmp/pkg.log
js_ready=$tmp/simplebrowse-js-ready
mkdir -p "$fixture/scripts" "$fake_bin" "$home"
cp "$repo/scripts/install-packages.sh" "$fixture/scripts/install-packages.sh"

cat >"$fixture/scripts/detect-platform.sh" <<'EOF'
#!/bin/sh
printf '%s\n' freebsd
EOF

cat >"$fake_bin/uname" <<'EOF'
#!/bin/sh
printf '%s\n' FreeBSD
EOF

cat >"$fake_bin/sudo" <<'EOF'
#!/bin/sh
exec "$@"
EOF

cat >"$fake_bin/pkg" <<'EOF'
#!/bin/sh
set -eu
case "${1-}" in
    update)
        printf '%s\n' update >>"$FAKE_PKG_LOG"
        ;;
    install)
        printf '%s\n' "$*" >>"$FAKE_PKG_LOG"
        : >"$FAKE_JS_READY"
        ;;
    info)
        exit 0
        ;;
    *)
        echo "unexpected pkg arguments: $*" >&2
        exit 2
        ;;
esac
EOF

cat >"$fake_bin/pkg-config" <<'EOF'
#!/bin/sh
[ "${1-}" = --exists ]
EOF

cat >"$fake_bin/gmake" <<'EOF'
#!/bin/sh
if [ "${1-}" = --version ]; then
    printf '%s\n' 'GNU Make 4.4'
fi
EOF

cat >"$fake_bin/python3" <<'EOF'
#!/bin/sh
[ -f "$FAKE_JS_READY" ]
EOF

for command_name in \
    cc git mpv pdftotext pandoc zip unzip tar file less fzf links mbsync \
    msmtp calcurse curl rsync nano crontab xdg-open gio umount bsdisks \
    e2fsck exfatfsck mount.exfat ntfsfix ifconfig route wpa_cli xclip pactl \
    parec avahi-daemon avahi-browse avahi-publish-service mount_nfs blkid nfsd \
    ssh sshd; do
    printf '%s\n' '#!/bin/sh' 'exit 0' >"$fake_bin/$command_name"
done

for utility in awk chmod cmp dirname env grep id mktemp rm sed stat tee; do
    ln -s "$(command -v "$utility")" "$fake_bin/$utility"
done
find "$fixture/scripts" "$fake_bin" -type f -exec chmod 755 {} +

HOME="$home" FAKE_PKG_LOG="$pkg_log" FAKE_JS_READY="$js_ready" \
PATH="$fake_bin" SIMPLESUITE_NETWORK_ROLE=server \
    "$fixture/scripts/install-packages.sh" >"$tmp/install.log" 2>&1

grep -q '^update$' "$pkg_log"
for package_name in devel/py-pygobject webkit2-gtk_41 avahi-app e2fsprogs; do
    grep -Eq "^install -y .*(^|[[:space:]])${package_name}([[:space:]]|$)" \
        "$pkg_log" || {
        echo "freebsd-package-bootstrap-check: pkg transaction omitted $package_name" >&2
        exit 1
    }
done
grep -q 'Package dependency installation verified' "$tmp/install.log"

: >"$pkg_log"
HOME="$home" FAKE_PKG_LOG="$pkg_log" FAKE_JS_READY="$js_ready" \
PATH="$fake_bin" SIMPLESUITE_NETWORK_ROLE=server \
    "$fixture/scripts/install-packages.sh" >"$tmp/recheck.log" 2>&1
[ ! -s "$pkg_log" ] || {
    echo 'freebsd-package-bootstrap-check: verified runtime triggered another pkg transaction' >&2
    exit 1
}
grep -q 'Package dependencies already present' "$tmp/recheck.log"

echo 'OK FreeBSD installs and verifies SimpleBrowse JavaScript and Trident dependencies'
