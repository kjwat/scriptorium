#!/bin/sh
set -eu

ROOT=${SCRIPTORIUM_ROOT:-$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)}
WEBSITE=${WEBSITE_DIR:-$HOME/website}
NETWORK_CLIENT_SETUP=${SCRIPTORIUM_NETWORK_CLIENT_SETUP:-$ROOT/scripts/setup-network-client.sh}
SYSTEM_ROOT=${SCRIPTORIUM_SYSTEM_ROOT:-}
BACKUP_PARENT=${SCRIPTORIUM_SERVER_BACKUP_DIR:-$HOME/.local/state/scriptorium/server-backups}
SERVICE_MANAGER=${WEBSITE_SERVICE_MANAGER:-}

case "$SYSTEM_ROOT" in
    '') ;;
    /*) [ "$SYSTEM_ROOT" != / ] || {
            echo "setup-server: refusing / as SCRIPTORIUM_SYSTEM_ROOT." >&2
            exit 2
        } ;;
    *)
        echo "setup-server: SCRIPTORIUM_SYSTEM_ROOT must be an absolute test path." >&2
        exit 2
        ;;
esac

root_path() {
    printf '%s%s\n' "$SYSTEM_ROOT" "$1"
}

run_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo "$@"
    else
        echo "setup-server: root privileges are required, but sudo is unavailable." >&2
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

backup_server_state() {
    backup_tool=$WEBSITE/tools/backup_server_state.py
    environment=$HOME/.config/keelanwatlington/store.env
    timestamp=$(date +%Y%m%d-%H%M%S)
    backup=$BACKUP_PARENT/server-$timestamp
    suffix=0

    mkdir -p "$BACKUP_PARENT"
    chmod 0700 "$BACKUP_PARENT"
    while [ -e "$backup" ]; do
        suffix=$((suffix + 1))
        backup=$BACKUP_PARENT/server-$timestamp-$suffix
    done
    if [ -f "$environment" ]; then
        [ -x "$backup_tool" ] || {
            echo "setup-server: website state exists, but its backup tool is unavailable: $backup_tool" >&2
            exit 1
        }
        "$backup_tool" "$backup" \
            --cloudflared-config "$backup.no-cloudflare-config" >&2
    else
        mkdir -m 0700 "$backup"
    fi

    copy_protected_state "$(root_path /etc/cloudflared/keelanwatlington.token)" \
        "$backup/cloudflared/token"
    copy_protected_state "$(root_path /etc/cloudflared/config.yml)" \
        "$backup/cloudflared/config.yml"
    copy_protected_state "$(root_path /etc/cloudflared/keelanwatlington-credentials.json)" \
        "$backup/cloudflared/credentials.json"
    printf '%s\n' "$backup"
}

detect_service_manager() {
    [ -z "$SERVICE_MANAGER" ] || return 0
    case "$(uname -s 2>/dev/null || true)" in
        Darwin) SERVICE_MANAGER=launchd ;;
        FreeBSD) SERVICE_MANAGER=freebsd ;;
        Linux)
            if command -v systemctl >/dev/null 2>&1 &&
               [ -d "$(root_path /run/systemd/system)" ]; then
                SERVICE_MANAGER=systemd
            elif command -v rc-service >/dev/null 2>&1 &&
                 command -v rc-update >/dev/null 2>&1; then
                SERVICE_MANAGER=openrc
            elif command -v sv >/dev/null 2>&1 &&
                 [ -d "$(root_path /etc/sv)" ]; then
                SERVICE_MANAGER=runit
            else
                SERVICE_MANAGER=unsupported
            fi
            ;;
        *) SERVICE_MANAGER=unsupported ;;
    esac
}

disable_systemd_unit() {
    unit=$1

    if run_root systemctl is-active --quiet "$unit" 2>/dev/null; then
        run_root systemctl stop "$unit"
    fi
    if run_root systemctl is-enabled --quiet "$unit" 2>/dev/null; then
        run_root systemctl disable "$unit"
    fi
}

disable_website_services() {
    detect_service_manager
    case "$SERVICE_MANAGER" in
        systemd)
            for unit in cloudflared.service keelanwatlington-blog-sync.timer \
                        keelanwatlington-blog-sync.service \
                        keelanwatlington-store.service caddy.service; do
                disable_systemd_unit "$unit"
            done
            run_root rm -f -- \
                "$(root_path /etc/systemd/system/keelanwatlington-store.service)" \
                "$(root_path /etc/systemd/system/keelanwatlington-blog-sync.service)" \
                "$(root_path /etc/systemd/system/keelanwatlington-blog-sync.timer)" \
                "$(root_path /etc/systemd/system/caddy.service.d/website.conf)"
            run_root rmdir "$(root_path /etc/systemd/system/caddy.service.d)" \
                2>/dev/null || true
            run_root systemctl daemon-reload
            ;;
        openrc)
            for service in keelanwatlington-cloudflared \
                           keelanwatlington-blog-sync \
                           keelanwatlington-store keelanwatlington-caddy; do
                run_root rc-service "$service" stop >/dev/null 2>&1 || true
                run_root rc-update del "$service" default >/dev/null 2>&1 || true
                run_root rm -f -- "$(root_path /etc/init.d/$service)"
            done
            ;;
        runit)
            for service in keelanwatlington-cloudflared \
                           keelanwatlington-blog-sync \
                           keelanwatlington-store keelanwatlington-caddy; do
                run_root sv down "$service" >/dev/null 2>&1 || true
                link=$(root_path "/var/service/$service")
                expected=/etc/sv/$service
                if run_root test -L "$link" &&
                   [ "$(run_root readlink "$link")" = "$expected" ]; then
                    run_root rm -f -- "$link"
                fi
                run_root rm -f -- "$(root_path /etc/sv/$service/run)"
                run_root rmdir "$(root_path /etc/sv/$service)" 2>/dev/null || true
            done
            ;;
        freebsd)
            for service in keelanwatlington_cloudflared \
                           keelanwatlington_blog_sync \
                           keelanwatlington_store keelanwatlington_caddy; do
                run_root service "$service" onestop >/dev/null 2>&1 || true
                run_root sysrc -q "${service}_enable=NO" >/dev/null 2>&1 || true
                run_root rm -f -- "$(root_path /usr/local/etc/rc.d/$service)"
            done
            ;;
        launchd)
            for label in com.keelanwatlington.cloudflared \
                         com.keelanwatlington.blog-sync \
                         com.keelanwatlington.store com.keelanwatlington.caddy; do
                run_root launchctl bootout "system/$label" >/dev/null 2>&1 || true
                run_root launchctl disable "system/$label" >/dev/null 2>&1 || true
                run_root rm -f -- \
                    "$(root_path /Library/LaunchDaemons/$label.plist)"
            done
            ;;
        *)
            echo "setup-server: no supported service manager was found for safe website shutdown." >&2
            exit 1
            ;;
    esac

    for launcher in caddy store blog cloudflared; do
        run_root rm -f -- \
            "$(root_path /usr/local/libexec/keelanwatlington/$launcher)"
    done
    run_root rmdir "$(root_path /usr/local/libexec/keelanwatlington)" \
        2>/dev/null || true
}

disable_share_publishers() {
    case "$SERVICE_MANAGER" in
        systemd)
            for unit in nfs-server.service nfs-kernel-server.service \
                        smbd.service smb.service samba.service; do
                disable_systemd_unit "$unit"
            done
            ;;
        openrc)
            for service in nfs nfs-server nfs-kernel-server samba smbd smb; do
                run_root rc-service "$service" stop >/dev/null 2>&1 || true
                run_root rc-update del "$service" default >/dev/null 2>&1 || true
            done
            ;;
        runit)
            for service in nfs-server smbd; do
                run_root sv down "$service" >/dev/null 2>&1 || true
                link=$(root_path "/var/service/$service")
                expected=/etc/sv/$service
                if run_root test -L "$link" &&
                   [ "$(run_root readlink "$link")" = "$expected" ]; then
                    run_root rm -f -- "$link"
                fi
            done
            ;;
        freebsd)
            for service in nfsd mountd samba_server; do
                run_root service "$service" onestop >/dev/null 2>&1 || true
            done
            for setting in nfs_server_enable mountd_enable samba_server_enable; do
                run_root sysrc -q "${setting}=NO" >/dev/null 2>&1 || true
            done
            ;;
        launchd)
            run_root nfsd disable >/dev/null 2>&1 || true
            ;;
    esac
}

[ -x "$NETWORK_CLIENT_SETUP" ] || {
    echo "setup-server: client-role setup is missing: $NETWORK_CLIENT_SETUP" >&2
    exit 1
}

role_file=$(root_path /etc/simpleserve-role)
[ -r "$role_file" ] && [ "$(tr -d '[:space:]' <"$role_file")" = server ] || {
    echo "setup-server: this machine is not configured as a Trident server." >&2
    exit 1
}

printf 'Creating a protected backup before withdrawing server services...\n'
backup=$(backup_server_state)
printf 'Stopping and disabling the website origin, store, blog sync, and public tunnel...\n'
disable_website_services
printf 'Withdrawing NFS/SMB publication and restoring the mount-only role...\n'
"$NETWORK_CLIENT_SETUP"
disable_share_publishers

printf '\nTrident server options were removed; this machine is now a client.\n'
printf '  preserved backup: %s\n' "$backup"
printf '  preserved data:   website checkout, store state, and installed packages\n'
printf '  client features:  LAN/Tailscale discovery, NFS mounts, and remembered reconnects\n'
printf 'Run setup-server later to restore the full server architecture.\n'
