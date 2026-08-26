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
SERVER_DEMOTION=${SCRIPTORIUM_SERVER_DEMOTION:-$SCRIPTORIUM_ROOT/scripts/demote-server.sh}
WEBSITE_SETUP=${SCRIPTORIUM_WEBSITE_SETUP:-$SCRIPTORIUM_ROOT/scripts/setup-website-server.sh}
ROLE_FILE=${SCRIPTORIUM_SIMPLESERVE_ROLE_FILE:-/etc/simpleserve-role}

die() {
    printf 'setup-server: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Usage: setup-server [--client]
       setup-server [WEBSITE SERVER OPTIONS]

Promote or reconcile the full Trident server: NFS/SMB publishing, persistent
removable drives, Caddy, Stripe fulfillment/recovery mail, blog sync, and the
Cloudflare tunnel.

  --client       safely back up and remove server activation, then return to
                 mount-only client mode
  --verify-only  verify the existing network and website server without changes
  -h, --help     show this help before touching either checkout

Running setup-server interactively on an existing server offers --client first.
Other options are handled by Scriptorium's website-server provisioner.
EOF
}

case "${1-}" in
    -h | --help)
        (($# == 1)) || die "--help does not accept other options"
        usage
        exit 0
        ;;
esac

maybe_demote_server() {
    local argument answer role= prompt=1 direct=0

    for argument in "$@"; do
        case $argument in
            --client) direct=1 ;;
            --verify-only | --non-interactive | -h | --help) prompt=0 ;;
        esac
    done
    if ((direct)); then
        (($# == 1)) || die "--client cannot be combined with server setup options"
        prompt=0
    fi
    [[ -r $ROLE_FILE ]] || {
        ((direct == 0)) || die "cannot read the installed SimpleServe role: $ROLE_FILE"
        return
    }
    role=$(tr -d '[:space:]' <"$ROLE_FILE")
    if [[ $role != server ]]; then
        if ((direct)); then
            [[ $role == client ]] || die "installed SimpleServe role is neither client nor server"
            printf 'This machine is already in Trident client mode.\n'
            exit 0
        fi
        return 0
    fi
    if ((direct)); then
        [[ -x $SERVER_DEMOTION ]] || die "safe server demotion is missing: $SERVER_DEMOTION"
        exec "$SERVER_DEMOTION"
    fi
    ((prompt)) || return 0

    printf '%s\n' \
        'This machine is currently a full Trident server.' \
        'You can safely withdraw NFS/SMB publication and website services while' \
        'preserving a protected backup, the website checkout, and client mounts.'
    printf 'Remove server mode and return this machine to client mode? [y/N] '
    IFS= read -r answer || answer=
    case $answer in
        y | Y | yes | YES)
            [[ -x $SERVER_DEMOTION ]] || die "safe server demotion is missing: $SERVER_DEMOTION"
            exec "$SERVER_DEMOTION"
            ;;
    esac
}

maybe_demote_server "$@"

case "$TARGET" in
    /|"$HOME"|"$HOME"/scriptorium|"$HOME"/simplesuite|"$HOME"/writing)
        die "unsafe website checkout path: $TARGET"
        ;;
esac
[[ $TARGET == /* ]] || die "WEBSITE_DIR must be an absolute path"
command -v git >/dev/null 2>&1 || die "git is required; run the Scriptorium installer first"
[[ -x $NETWORK_SETUP ]] || die "Trident server setup is missing: $NETWORK_SETUP"
[[ -x $WEBSITE_SETUP ]] || die "Scriptorium website setup is missing: $WEBSITE_SETUP"

network_arguments=()
for argument in "$@"; do
    if [[ $argument == --verify-only ]]; then
        network_arguments=(--verify-only)
        break
    fi
done
if [[ -d $TARGET/.git ]]; then
    if [[ -n $(git -C "$TARGET" status --porcelain) ]]; then
        die "$TARGET has uncommitted changes; review them before updating the website payload"
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

"$NETWORK_SETUP" "${network_arguments[@]}"
exec env WEBSITE_DIR="$TARGET" SCRIPTORIUM_ROOT="$SCRIPTORIUM_ROOT" \
    "$WEBSITE_SETUP" "$@"
