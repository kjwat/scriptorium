#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SOURCE="$ROOT/simplecheck.c"
DEST="$HOME/.local/bin/simplecheck"
CC_BIN="${CC:-cc}"

if [[ ! -f "$SOURCE" ]]; then
    printf 'Missing SimpleCheck source: %s\n' "$SOURCE" >&2
    exit 1
fi

mkdir -p "$HOME/.local/bin"
tmp="$(mktemp "${TMPDIR:-/tmp}/simplecheck.XXXXXX")"

cleanup() {
    rm -f "$tmp"
}
trap cleanup EXIT INT TERM

common_flags=(
    -std=c11
    -O2
    -Wall
    -Wextra
)

if command -v pkg-config >/dev/null 2>&1 &&
   pkg-config --exists ncursesw; then
    # shellcheck disable=SC2046
    "$CC_BIN" "${common_flags[@]}" \
        $(pkg-config --cflags ncursesw) \
        "$SOURCE" -o "$tmp" \
        $(pkg-config --libs ncursesw)
elif command -v pkg-config >/dev/null 2>&1 &&
     pkg-config --exists ncurses; then
    # shellcheck disable=SC2046
    "$CC_BIN" "${common_flags[@]}" \
        $(pkg-config --cflags ncurses) \
        "$SOURCE" -o "$tmp" \
        $(pkg-config --libs ncurses)
else
    "$CC_BIN" "${common_flags[@]}" \
        "$SOURCE" -o "$tmp" -lncursesw 2>/dev/null ||
    "$CC_BIN" "${common_flags[@]}" \
        "$SOURCE" -o "$tmp" -lncurses
fi

install -m 0755 "$tmp" "$DEST"
printf 'Installed %s\n' "$DEST"
