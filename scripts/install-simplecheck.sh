#!/bin/sh
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
SOURCE="$ROOT/simplecheck.c"
DEST="$HOME/.local/bin/simplecheck"
ALIAS_DEST="$HOME/.local/bin/check"
CC_BIN="${CC:-cc}"

prepend_pkgconfig_dir() {
    dir=$1
    [ -d "$dir" ] || return 0
    case ":${PKG_CONFIG_PATH:-}:" in
        *":$dir:"*) ;;
        *) PKG_CONFIG_PATH="$dir${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}" ;;
    esac
}

if [ "$(uname -s 2>/dev/null || true)" = Darwin ] &&
   command -v brew >/dev/null 2>&1; then
    ncurses_prefix="$(brew --prefix ncurses 2>/dev/null || true)"
    [ -z "$ncurses_prefix" ] || prepend_pkgconfig_dir "$ncurses_prefix/lib/pkgconfig"
    export PKG_CONFIG_PATH
fi

if [ ! -f "$SOURCE" ]; then
    printf 'Missing SimpleCheck source: %s\n' "$SOURCE" >&2
    exit 1
fi

mkdir -p "$HOME/.local/bin"
if [ -e "$ALIAS_DEST" ] || [ -L "$ALIAS_DEST" ]; then
    if [ ! -L "$ALIAS_DEST" ] ||
       [ "$(readlink "$ALIAS_DEST")" != simplecheck ]; then
        printf 'Refusing to replace unrelated check command: %s\n' \
            "$ALIAS_DEST" >&2
        exit 1
    fi
fi
tmp="$(mktemp "${TMPDIR:-/tmp}/simplecheck.XXXXXX")"

cleanup() {
    rm -f "$tmp"
}
trap cleanup EXIT INT TERM

common_flags="-std=c11 -O2 -Wall -Wextra"

if command -v pkg-config >/dev/null 2>&1 &&
   pkg-config --exists ncursesw; then
    # shellcheck disable=SC2046
    "$CC_BIN" $common_flags \
        $(pkg-config --cflags ncursesw) \
        "$SOURCE" -o "$tmp" \
        $(pkg-config --libs ncursesw)
elif command -v pkg-config >/dev/null 2>&1 &&
     pkg-config --exists ncurses; then
    # shellcheck disable=SC2046
    "$CC_BIN" $common_flags \
        $(pkg-config --cflags ncurses) \
        "$SOURCE" -o "$tmp" \
        $(pkg-config --libs ncurses)
else
    "$CC_BIN" $common_flags \
        "$SOURCE" -o "$tmp" -lncursesw 2>/dev/null ||
    "$CC_BIN" $common_flags \
        "$SOURCE" -o "$tmp" -lncurses
fi

install -m 0755 "$tmp" "$DEST"

if [ ! -L "$ALIAS_DEST" ]; then
    ln -s simplecheck "$ALIAS_DEST"
fi

printf 'Installed %s and %s\n' "$DEST" "$ALIAS_DEST"
