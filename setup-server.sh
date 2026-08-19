#!/usr/bin/env bash
set -euo pipefail

TARGET=${WEBSITE_DIR:-$HOME/website}
REPOSITORY=${WEBSITE_REPO_URL:-https://github.com/kjwat/website.git}
SOURCE_ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
if [[ -x $SOURCE_ROOT/scripts/setup-network-server.sh ]]; then
    DEFAULT_SCRIPTORIUM_ROOT=$SOURCE_ROOT
else
    DEFAULT_SCRIPTORIUM_ROOT=$HOME/scriptorium
fi
SCRIPTORIUM_ROOT=${SCRIPTORIUM_ROOT:-$DEFAULT_SCRIPTORIUM_ROOT}
NETWORK_SETUP=${SCRIPTORIUM_NETWORK_SETUP:-$SCRIPTORIUM_ROOT/scripts/setup-network-server.sh}

die() {
    printf 'setup-server: %s\n' "$*" >&2
    exit 1
}

case "$TARGET" in
    /|"$HOME"|"$HOME"/scriptorium|"$HOME"/simplesuite|"$HOME"/writing)
        die "unsafe website checkout path: $TARGET"
        ;;
esac
[[ $TARGET == /* ]] || die "WEBSITE_DIR must be an absolute path"
command -v git >/dev/null 2>&1 || die "git is required; run the Scriptorium installer first"
[[ -x $NETWORK_SETUP ]] || die "Trident server setup is missing: $NETWORK_SETUP"

network_arguments=()
for argument in "$@"; do
    if [[ $argument == --verify-only ]]; then
        network_arguments=(--verify-only)
        break
    fi
done
if [[ -d $TARGET/.git ]]; then
    if [[ -n $(git -C "$TARGET" status --porcelain) ]]; then
        die "$TARGET has uncommitted changes; review them before updating the server installer"
    fi
    printf 'Updating existing website checkout...\n'
    GIT_TERMINAL_PROMPT=1 git -C "$TARGET" pull --ff-only
else
    if [[ -e $TARGET ]]; then
        [[ -d $TARGET && -z $(find "$TARGET" -mindepth 1 -maxdepth 1 -print -quit) ]] ||
            die "$TARGET exists and is not an empty directory"
        rmdir "$TARGET"
    fi

    clone_root=$(mktemp -d "${TMPDIR:-/tmp}/website-bootstrap.XXXXXX")
    cleanup() {
        rm -rf -- "$clone_root"
    }
    trap cleanup EXIT INT TERM

    printf 'Cloning website into %s...\n' "$TARGET"
    GIT_TERMINAL_PROMPT=1 git clone "$REPOSITORY" "$clone_root/website"
    mkdir -p "$(dirname -- "$TARGET")"
    mv "$clone_root/website" "$TARGET"
    rmdir "$clone_root"
    trap - EXIT INT TERM
fi

installer=$TARGET/tools/setup_server.sh
[[ -x $installer ]] || die "website installer is missing or not executable: $installer"
"$NETWORK_SETUP" "${network_arguments[@]}"
exec "$installer" "$@"
