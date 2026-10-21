#!/bin/sh

scriptorium_program_aliases() {
    {
    manifest=${SIMPLESUITE_MANIFEST_FILE:-${SIMPLESUITE_DIR:-$HOME/simplesuite}/program-manifest.sh}
    if [ -r "$manifest" ]; then
        . "$manifest"
        simplesuite_program_aliases "$1" "$2"
    else
        installed=${SIMPLESUITE_INSTALLED_MANIFEST:-${SIMPLESUITE_SYSTEM_DATA_DIR:-/usr/local/share/simplesuite}/command-abbreviations}
        [ -r "$installed" ] && awk 'NF == 2 && $1 !~ /^#/ { print $1 ":" $2 }' "$installed"
    fi
    # These desktop programs have separate installers and are intentionally
    # absent from the command-line Suite manifest.
    if command -v simplesuite_desktop_aliases >/dev/null 2>&1; then
        simplesuite_desktop_aliases "$1"
    else
        printf '%s\n' 'term:simpleterm'
        case $1 in Linux | FreeBSD) printf '%s\n' 'play:simpleplay' 'pdf:simplepdf' ;; esac
    fi
    printf '%s\n' 'check:simplecheck' 'trident:simpletrident'
    } | awk -F: '!seen[$1]++'
}

scriptorium_suite_programs() {
    scriptorium_program_aliases "$1" "$2" |
        while IFS=: read -r short full; do
            case $full in
                simplecheck | simpletrident | simpleterm | simpleplay | simplepdf) ;;
                *) printf '%s\n' "$full" ;;
            esac
        done
    if [ "${2:-0}" = 1 ]; then
        printf '%s\n' simpleserved
    fi
}
