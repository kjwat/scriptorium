#!/bin/sh

scriptorium_program_aliases() {
    manifest=${SIMPLESUITE_MANIFEST_FILE:-${SIMPLESUITE_DIR:-$HOME/simplesuite}/program-manifest.sh}
    if [ -r "$manifest" ]; then
        . "$manifest"
        simplesuite_program_aliases "$1" "$2"
    else
        installed=${SIMPLESUITE_INSTALLED_MANIFEST:-$HOME/.local/share/simplesuite/command-abbreviations}
        [ -r "$installed" ] && cat "$installed"
    fi
    printf '%s\n' 'check:simplecheck' 'trident:simpletrident'
}

scriptorium_suite_programs() {
    scriptorium_program_aliases "$1" "$2" |
        while IFS=: read -r short full; do
            case $full in
                simplecheck | simpletrident) ;;
                *) printf '%s\n' "$full" ;;
            esac
        done
    if [ "${2:-0}" = 1 ]; then
        printf '%s\n' simpleserved
    fi
}
