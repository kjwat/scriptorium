#!/bin/sh
set -eu

ROOT=${SCRIPTORIUM_ROOT:-$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)}
BACKUP_TOOL=$ROOT/scripts/server/backup_server_state.py
SYSTEM_ROOT=${SCRIPTORIUM_SYSTEM_ROOT:-}

case "$SYSTEM_ROOT" in
    '') ;;
    /*) [ "$SYSTEM_ROOT" != / ] || {
            echo "backup-server-state: refusing / as SCRIPTORIUM_SYSTEM_ROOT." >&2
            exit 2
        } ;;
    *)
        echo "backup-server-state: SCRIPTORIUM_SYSTEM_ROOT must be an absolute test path." >&2
        exit 2
        ;;
esac

[ "$#" -eq 1 ] || {
    echo "Usage: $0 OUTPUT-DIRECTORY" >&2
    exit 2
}
[ -x "$BACKUP_TOOL" ] || {
    echo "backup-server-state: Scriptorium backup tool is unavailable: $BACKUP_TOOL" >&2
    exit 1
}

root_path() {
    printf '%s%s\n' "$SYSTEM_ROOT" "$1"
}

run_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo "$@"
    else
        echo "backup-server-state: root privileges are required for protected tunnel state, but sudo is unavailable." >&2
        return 127
    fi
}

copy_protected_state() {
    source=$1
    destination=$2

    if run_root test -f "$source"; then
        mkdir -p "$(dirname -- "$destination")"
        chmod 0700 "$(dirname -- "$destination")"
        run_root install -m 0600 -o "$(id -u)" -g "$(id -g)" \
            "$source" "$destination"
    fi
}

output=$1
case "$output" in
    /*) ;;
    *) output=$PWD/$output ;;
esac

if [ -f "$HOME/.config/keelanwatlington/store.env" ]; then
    "$BACKUP_TOOL" "$output" --cloudflared-config "$output.no-cloudflare-config"
else
    [ ! -e "$output" ] || {
        echo "backup-server-state: refusing to overwrite existing path: $output" >&2
        exit 1
    }
    mkdir -m 0700 "$output"
fi
copy_protected_state "$(root_path /etc/cloudflared/keelanwatlington.token)" \
    "$output/cloudflared/token"
copy_protected_state "$(root_path /etc/cloudflared/keelanwatlington-api.token)" \
    "$output/cloudflared/api-token"
copy_protected_state "$(root_path /etc/cloudflared/config.yml)" \
    "$output/cloudflared/config.yml"
copy_protected_state "$(root_path /etc/cloudflared/keelanwatlington-credentials.json)" \
    "$output/cloudflared/credentials.json"

printf 'protected server state backed up to %s\n' "$output"
