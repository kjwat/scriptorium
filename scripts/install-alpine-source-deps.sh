#!/bin/sh
# Build unavailable stable-Alpine dependencies as checksum-pinned native APKs.
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
command -v apk >/dev/null 2>&1 || { echo 'This dependency builder requires Alpine apk.' >&2; exit 2; }
[ "$(id -u)" = 0 ] || { echo 'Run the Alpine source dependency builder with administrator privileges.' >&2; exit 1; }
# Calibre interprets sudo's caller IDs as a request to drop build privileges.
# abuild owns its build tree; inherited caller IDs do not describe that owner.
unset SUDO_UID SUDO_GID SUDO_USER
need_sid=0
need_calibre=0
pkg-config --exists libsidplayfp || need_sid=1
calibre_debug=$(command -v calibre-debug || true)
if [ -z "$calibre_debug" ] && [ -x /opt/calibre/calibre-debug ]; then calibre_debug=/opt/calibre/calibre-debug; fi
calibre_convert=$(command -v ebook-convert || true)
if [ -z "$calibre_convert" ] && [ -x /opt/calibre/ebook-convert ]; then calibre_convert=/opt/calibre/ebook-convert; fi
if [ -z "$calibre_debug" ] || [ -z "$calibre_convert" ] || ! "$calibre_debug" -c 'from calibre_extensions import podofo' >/dev/null 2>&1; then
    need_calibre=1
fi
[ "$need_sid:$need_calibre" != 0:0 ] || exit 0

apk add abuild alpine-sdk openssl curl python3 py3-installer
build=$ROOT/build/alpine-source
mkdir -p "$build/keys" "$build/distfiles" "$build/packages" "$build/recipes/main"
PACKAGER_PRIVKEY=$build/keys/scriptorium-source.rsa
export PACKAGER_PRIVKEY
if [ ! -f "$PACKAGER_PRIVKEY" ]; then
    (umask 077; openssl genrsa -out "$PACKAGER_PRIVKEY" 2048)
fi
openssl rsa -in "$PACKAGER_PRIVKEY" -pubout -out "$PACKAGER_PRIVKEY.pub"
trust=$(mktemp -d /tmp/scriptorium-alpine-keys.XXXXXX)
trap 'rm -rf -- "$trust"' EXIT HUP INT TERM
for key in /etc/apk/keys/*; do [ ! -f "$key" ] || cp "$key" "$trust/"; done
cp "$PACKAGER_PRIVKEY.pub" "$trust/"
ABUILD_CONF=/dev/null
ABUILD_USERCONF=/dev/null
ABUILD_USERDIR=$build/keys
SRCDEST=$build/distfiles
REPODEST=$build/packages
APK="apk --keys-dir $trust"
SUDO_APK=$APK
JOBS=${SIMPLESUITE_JOBS:-4}
PACKAGER='Scriptorium source dependencies'
export ABUILD_CONF ABUILD_USERCONF ABUILD_USERDIR SRCDEST REPODEST APK SUDO_APK JOBS PACKAGER

build_package() {
    package=$1
    target=$build/recipes/main/$package
    mkdir -p "$target"
    cp -R "$ROOT/packages/alpine-source/$package/." "$target/"
    echo "Building pinned Alpine source dependency: $package"
    (cd "$target" && abuild -Fr)
    # Use only the APKs just produced by this recipe and the private build key.
    built_version=$( . "$target/APKBUILD"; printf '%s-r%s' "$pkgver" "$pkgrel")
    built_apk=$REPODEST/main/$(apk --print-arch)/$package-$built_version.apk
    [ -f "$built_apk" ] || { echo "No built APK for $package" >&2; exit 1; }
    apk --keys-dir "$trust" add "$built_apk"
}

if [ "$need_sid" = 1 ]; then
    build_package libsidplayfp
    apk --keys-dir "$trust" add "$REPODEST/main/$(apk --print-arch)/libsidplayfp-dev-$built_version.apk"
fi
if [ "$need_calibre" = 1 ]; then
    python3 -c 'import apsw' >/dev/null 2>&1 || build_package py3-apsw
    python3 -c 'import html5_parser' >/dev/null 2>&1 || build_package py3-html5-parser
    build_package calibre
fi
pkg-config --exists libsidplayfp
if [ "$need_calibre" = 1 ]; then
    ebook-convert --version
    calibre-debug --version
    calibre-debug -c 'from calibre_extensions import podofo'
fi
echo 'Alpine source dependencies built and installed successfully.'
