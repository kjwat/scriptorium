#!/bin/sh
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
SOURCE="$ROOT/simpletrident.c"
DEST="$HOME/.local/bin/simpletrident"
ALIAS_DEST="$HOME/.local/bin/trident"
CC_BIN="${CC:-cc}"

prepend_pkgconfig_dir() {
    directory=$1
    [ -d "$directory" ] || return 0
    case ":${PKG_CONFIG_PATH:-}:" in
        *":$directory:"*) ;;
        *) PKG_CONFIG_PATH="$directory${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}" ;;
    esac
}

if [ "$(uname -s 2>/dev/null || true)" = Darwin ] &&
   command -v brew >/dev/null 2>&1; then
    ncurses_prefix="$(brew --prefix ncurses 2>/dev/null || true)"
    [ -z "$ncurses_prefix" ] || prepend_pkgconfig_dir "$ncurses_prefix/lib/pkgconfig"
    export PKG_CONFIG_PATH
fi

if [ ! -f "$SOURCE" ]; then
    printf 'Missing SimpleTrident source: %s\n' "$SOURCE" >&2
    exit 1
fi

mkdir -p "$HOME/.local/bin"
if [ -e "$ALIAS_DEST" ] || [ -L "$ALIAS_DEST" ]; then
    if [ ! -L "$ALIAS_DEST" ] ||
       [ "$(readlink "$ALIAS_DEST")" != simpletrident ]; then
        printf 'Refusing to replace unrelated trident command: %s\n' \
            "$ALIAS_DEST" >&2
        exit 1
    fi
fi
temporary="$(mktemp "${TMPDIR:-/tmp}/simpletrident.XXXXXX")"

cleanup() {
    rm -f "$temporary"
}
trap cleanup EXIT INT TERM

common_flags="-std=c11 -O2 -Wall -Wextra"

if command -v pkg-config >/dev/null 2>&1 &&
   pkg-config --exists ncursesw; then
    # shellcheck disable=SC2046
    "$CC_BIN" $common_flags \
        $(pkg-config --cflags ncursesw) \
        "$SOURCE" -o "$temporary" \
        $(pkg-config --libs ncursesw)
elif command -v pkg-config >/dev/null 2>&1 &&
     pkg-config --exists ncurses; then
    # shellcheck disable=SC2046
    "$CC_BIN" $common_flags \
        $(pkg-config --cflags ncurses) \
        "$SOURCE" -o "$temporary" \
        $(pkg-config --libs ncurses)
else
    "$CC_BIN" $common_flags \
        "$SOURCE" -o "$temporary" -lncursesw 2>/dev/null ||
    "$CC_BIN" $common_flags \
        "$SOURCE" -o "$temporary" -lncurses
fi

install -m 0755 "$temporary" "$DEST"
if [ ! -L "$ALIAS_DEST" ]; then
    ln -s simpletrident "$ALIAS_DEST"
fi
printf 'Installed %s and %s\n' "$DEST" "$ALIAS_DEST"
