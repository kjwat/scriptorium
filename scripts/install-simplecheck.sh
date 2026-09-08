#!/bin/sh
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
SOURCE="$ROOT/simplecheck.c"
SYSTEM_BIN_DIR="${SIMPLESUITE_SYSTEM_BIN_DIR:-/usr/local/bin}"
DEST="$SYSTEM_BIN_DIR/simplecheck"
LEGACY_DEST="$HOME/.local/bin/simplecheck"
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

# Match the suite installer, including its override for staged/test installs.
run_install_command() {
    if [ "$(id -u)" -eq 0 ] || [ -w "$SYSTEM_BIN_DIR" ]; then
        "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo "$@"
    elif command -v doas >/dev/null 2>&1; then
        doas "$@"
    else
        printf 'Root privileges are required to install SimpleCheck in %s.\n' "$SYSTEM_BIN_DIR" >&2
        exit 1
    fi
}

remove_legacy_commands() {
    [ "$DEST" = "$LEGACY_DEST" ] || rm -f "$LEGACY_DEST"
    if [ -L "$ALIAS_DEST" ] && [ "$(readlink "$ALIAS_DEST")" = simplecheck ]; then
        rm -f "$ALIAS_DEST"
    fi
}

if [ -e "$ALIAS_DEST" ] || [ -L "$ALIAS_DEST" ]; then
    if [ -L "$ALIAS_DEST" ] &&
       [ "$(readlink "$ALIAS_DEST")" = simplecheck ]; then
        : # Remove this only after the system command is available.
    else
        printf 'Refusing to replace unrelated check command: %s\n' \
            "$ALIAS_DEST" >&2
        exit 1
    fi
fi
if [ -x "$DEST" ]; then
    remove_legacy_commands
    printf 'Reusing existing %s; Bash installs alias check=%s\n' "$DEST" "$DEST"
    exit 0
fi
tmp="$(mktemp "${TMPDIR:-/tmp}/simplecheck.XXXXXX")"
system_tmp=

cleanup() {
    rm -f "$tmp"
    [ -z "$system_tmp" ] || run_install_command rm -f "$system_tmp"
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

run_install_command mkdir -p "$SYSTEM_BIN_DIR"
system_tmp=$(run_install_command mktemp "$SYSTEM_BIN_DIR/.simplecheck.XXXXXX")
run_install_command install -m 0755 "$tmp" "$system_tmp"
run_install_command mv -f "$system_tmp" "$DEST"
system_tmp=
remove_legacy_commands
printf 'Installed %s (shell alias: check)\n' "$DEST"
