#!/bin/sh
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BASH_BIN=$(command -v bash)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/scriptorium-macos-packages.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

fake_bin=$tmp/bin
home=$tmp/home
brew_root=$tmp/homebrew
brew_log=$tmp/brew.log
mkdir -p "$fake_bin" "$home" "$brew_root"

cat >"$fake_bin/uname" <<'EOF'
#!/bin/sh
echo Darwin
EOF

cat >"$fake_bin/sw_vers" <<'EOF'
#!/bin/sh
printf '%s\n' "${FAKE_MACOS_VERSION:-15.5}"
EOF

cat >"$fake_bin/xcode-select" <<'EOF'
#!/bin/sh
[ "${1-}" = -p ] || exit 2
echo /Library/Developer/CommandLineTools
EOF

cat >"$fake_bin/xcrun" <<'EOF'
#!/bin/sh
case "${1-}" in
    --find) echo /usr/bin/clang ;;
    --sdk) printf '%s\n' "${FAKE_SDK_VERSION:-15.5}" ;;
    *) exit 2 ;;
esac
EOF

cat >"$fake_bin/pkg-config" <<'EOF'
#!/bin/sh
[ "${1-}" = --exists ]
EOF

cat >"$fake_bin/gmake" <<'EOF'
#!/bin/sh
if [ "${1-}" = --version ]; then
    echo 'GNU Make 4.4'
fi
EOF

cat >"$fake_bin/brew" <<'EOF'
#!/bin/sh
set -eu

case "${1-}" in
    --prefix)
        prefix="$FAKE_BREW_ROOT/${2-}"
        mkdir -p "$prefix/lib/pkgconfig" "$prefix/share/pkgconfig"
        printf '%s\n' "$prefix"
        ;;
    install)
        shift
        printf '%s\n' "$*" >>"$FAKE_BREW_LOG"
        printf '%s\n' '#!/bin/sh' 'exit 0' >"$FAKE_BIN/mpv"
        chmod 755 "$FAKE_BIN/mpv"
        ;;
    *)
        echo "unexpected brew arguments: $*" >&2
        exit 2
        ;;
esac
EOF

for command_name in \
    cc git pdftotext pandoc zip unzip tar file less fzf links mbsync msmtp \
    calcurse curl rsync nano open launchctl dns-sd mount_nfs nfsd sharing; do
    printf '%s\n' '#!/bin/sh' 'exit 0' >"$fake_bin/$command_name"
done
chmod 755 "$fake_bin"/*

for utility in chmod dirname env grep mkdir mktemp rm tee; do
    ln -s "$(command -v "$utility")" "$fake_bin/$utility"
done

HOME="$home" \
FAKE_BIN="$fake_bin" \
FAKE_BREW_ROOT="$brew_root" \
FAKE_BREW_LOG="$brew_log" \
PATH="$fake_bin" \
    "$repo/scripts/install-packages.sh" >"$tmp/install.log" 2>&1

grep -q '^pkgconf ncurses curl make openssl@3 glib git mpv poppler pandoc nano zip unzip libmagic less fzf isync msmtp calcurse links rsync$' \
    "$brew_log"
if grep -q 'pulseaudio' "$brew_log"; then
    echo 'macos-package-bootstrap-check: native macOS path installed PulseAudio' >&2
    exit 1
fi
grep -q 'Package dependency installation verified' "$tmp/install.log"

HOME="$home" \
FAKE_BIN="$fake_bin" \
FAKE_BREW_ROOT="$brew_root" \
FAKE_BREW_LOG="$brew_log" \
PATH="$fake_bin:/usr/bin:/bin" \
    "$BASH_BIN" "$repo/scripts/checkdeps.sh" >"$tmp/checkdeps.log" 2>&1
grep -q 'native WKWebView helper' "$tmp/checkdeps.log"
grep -q 'native Core Audio tap' "$tmp/checkdeps.log"
if grep -Eq 'pactl|parec|pulseaudio' "$tmp/checkdeps.log"; then
    echo 'macos-package-bootstrap-check: macOS dependency report requested PulseAudio tooling' >&2
    exit 1
fi

install_count=$(wc -l <"$brew_log" | tr -d ' ')
rm -f "$fake_bin/mpv"
set +e
HOME="$home" \
FAKE_BIN="$fake_bin" \
FAKE_BREW_ROOT="$brew_root" \
FAKE_BREW_LOG="$brew_log" \
FAKE_MACOS_VERSION=13.6 \
PATH="$fake_bin:/usr/bin:/bin" \
    "$repo/scripts/install-packages.sh" >"$tmp/old-macos.log" 2>&1
old_status=$?
set -e
[ "$old_status" -ne 0 ]
grep -q 'requires macOS 14.2 or newer' "$tmp/old-macos.log"
[ "$(wc -l <"$brew_log" | tr -d ' ')" -eq "$install_count" ]

echo 'OK Scriptorium detects macOS and installs the native Homebrew package set'
