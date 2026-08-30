#!/bin/sh

# Canonical Scriptorium program/alias master list.  The left side is a shell
# convenience only; the right side is the sole executable name installed in
# ~/.local/bin.
SCRIPTORIUM_BASE_PROGRAM_ALIASES='browse:simplebrowse
cal:simplecal
check:simplecheck
clock:simpleclock
files:simplefiles
flac:simpleflac
game:simplegame
mail:simplemail
news:simplenews
pdf:simplepdf
pod:simplepod
radio:simpleradio
stats:simplestats
suite-uninstall:simplesuite-uninstall
trident:simpletrident
ver:simplever
vis:simplevis
words:simplewords'

scriptorium_program_aliases() {
    printf '%s\n' "$SCRIPTORIUM_BASE_PROGRAM_ALIASES"
    case ${1:-$(uname -s 2>/dev/null || true)} in
        Linux)
            printf '%s\n' 'net:simplenet' 'blue:simpleblue'
            ;;
        FreeBSD)
            printf '%s\n' 'net:simplenet'
            ;;
    esac
    if [ "${2:-0}" = 1 ]; then
        printf '%s\n' 'serve:simpleserve'
    fi
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
