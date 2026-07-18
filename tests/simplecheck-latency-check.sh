#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
CC_BIN="${CC:-cc}"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/simplecheck-latency-check.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

common_flags=(
    -std=c11
    -O2
    -Wall
    -Wextra
    -Wpedantic
)

if command -v pkg-config >/dev/null 2>&1 &&
   pkg-config --exists ncursesw; then
    # shellcheck disable=SC2046
    "$CC_BIN" "${common_flags[@]}" \
        $(pkg-config --cflags ncursesw) \
        "$ROOT/tests/simplecheck-latency-check.c" -o "$TMP/check" \
        $(pkg-config --libs ncursesw)
elif command -v pkg-config >/dev/null 2>&1 &&
     pkg-config --exists ncurses; then
    # shellcheck disable=SC2046
    "$CC_BIN" "${common_flags[@]}" \
        $(pkg-config --cflags ncurses) \
        "$ROOT/tests/simplecheck-latency-check.c" -o "$TMP/check" \
        $(pkg-config --libs ncurses)
else
    "$CC_BIN" "${common_flags[@]}" \
        "$ROOT/tests/simplecheck-latency-check.c" -o "$TMP/check" \
        -lncursesw 2>/dev/null ||
    "$CC_BIN" "${common_flags[@]}" \
        "$ROOT/tests/simplecheck-latency-check.c" -o "$TMP/check" \
        -lncurses
fi

"$TMP/check"
