#!/bin/sh
# Check actual installed bytes, including programs with standalone installers.
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
suite=${SIMPLESUITE_DIR:-$HOME/simplesuite}
bindir=${SIMPLESUITE_SYSTEM_BIN_DIR:-/usr/local/bin}
datadir=${SIMPLESUITE_SYSTEM_DATA_DIR:-/usr/local/share/simplesuite}
host=$(uname -s)
. "$ROOT/scripts/resolve-simpleserve-role.sh"
role=$(scriptorium_resolve_simpleserve_role)
network=1
[ "$role" != none ] || network=0
. "$suite/program-manifest.sh"

verify_file() {
    if [ ! -r "$1" ] || [ ! -r "$2" ] || ! cmp -s "$1" "$2"; then
        printf 'Stale or missing installed file: %s (expected %s)\n' "$2" "$1" >&2
        exit 1
    fi
    printf '  verified: %s\n' "$2"
}

scripts=${SIMPLESUITE_SCRIPTS:-simplebrowse-webkitd simplebrowse-jsdump simplesuite-uninstall}
case $host in
    Linux) scripts="$scripts simplevol-audio" ;;
    Darwin) scripts="$scripts simplefiles-macos-helper simplevis-macos-capture" ;;
esac
programs=$({ simplesuite_programs "$host" "$network"; printf '%s\n' $scripts; } | awk '!seen[$0]++')
for program in $programs; do
    case $program in
        simpleserved) continue ;; # SimpleOS deliberately owns the frozen daemon.
        simplesuite-uninstall) source=$suite/uninstall.sh ;;
        simplebrowse-webkitd)
            case $host in Darwin) source=$suite/build/$program ;; *) source=$suite/$program ;; esac ;;
        simplebrowse-jsdump|simplevol-audio|simplechange-engine|simplefiles-macos-helper|simplevis-macos-capture)
            source=$suite/$program ;;
        *) source=$suite/build/$program ;;
    esac
    verify_file "$source" "$bindir/$program"
done
desktop=$(simplesuite_desktop_aliases "$host" | sed 's/.*://')
for program in $desktop simpleplay-core; do
    case $program in
        simpleterm) directory=${SIMPLETERM_BUILD_DIR:-$suite/build} ;;
        simplepdf) directory=${SIMPLEPDF_BUILD_DIR:-$suite/build} ;;
        *) directory=${SIMPLEPLAY_BUILD_DIR:-$suite/build} ;;
    esac
    case $directory in /*) ;; *) directory=$suite/$directory ;; esac
    verify_file "$directory/$program" "$bindir/$program"
done
for program in simplecheck simpletrident; do
    verify_file "$ROOT/build/$program" "$bindir/$program"
done
verify_file "$ROOT/setup-server.sh" "$bindir/setup-server"
verify_file "$suite/program-manifest.sh" "$datadir/program-manifest.sh"
sha=$(git -C "$suite" rev-parse HEAD)
[ "$("$bindir/simplewords" --version)" = "simplewords $sha" ] || {
    printf 'Installed SimpleWords does not identify current source revision %s.\n' "$sha" >&2
    exit 1
}
grep -qx "simplesuite_source_sha=$sha" "$datadir/install-manifest"
grep -qx "simplewords_build_revision=$sha" "$datadir/install-manifest"
printf 'Verified the complete installed program set against SimpleSuite %s.\n' "$sha"
