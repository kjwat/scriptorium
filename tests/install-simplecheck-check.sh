#!/bin/sh
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/scriptorium-simplecheck-install.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

for short in check trident; do
    program=simple$short
    test_home=$TMP/$short/home
    system_bin=$TMP/$short/system-bin
    legacy_bin=$test_home/.local/bin
    mkdir -p "$legacy_bin" "$system_bin"

    run_installer() {
        HOME="$test_home" SIMPLESUITE_SYSTEM_BIN_DIR="$system_bin" \
            "$ROOT/scripts/install-$program.sh"
    }

    printf '%s\n' legacy >"$legacy_bin/$program"
    chmod 755 "$legacy_bin/$program"
    ln -s "$program" "$legacy_bin/$short"
    ln -s "$program" "$system_bin/$short"
    printf '%s\n' personal >"$legacy_bin/ytmp3"

    # A failed install must leave the old command and its alias usable.
    mkdir -p "$TMP/fail-bin"
    printf '%s\n' '#!/bin/sh' 'exit 1' >"$TMP/fail-bin/install"
    chmod 755 "$TMP/fail-bin/install"
    if PATH="$TMP/fail-bin:$PATH" run_installer >"$TMP/$short-failed.log" 2>&1; then
        echo "$program check: failed install was accepted" >&2
        exit 1
    fi
    [ "$(cat "$legacy_bin/$program")" = legacy ]
    [ "$(readlink "$legacy_bin/$short")" = "$program" ]
    [ ! -e "$system_bin/$program" ]
    [ "$(readlink "$system_bin/$short")" = "$program" ]

    run_installer >"$TMP/$short-first-install.log"
    [ -x "$system_bin/$program" ]
    [ ! -e "$legacy_bin/$program" ]
    [ ! -L "$legacy_bin/$short" ]
    [ ! -e "$system_bin/$short" ]
    [ "$(cat "$legacy_bin/ytmp3")" = personal ]

    # Reusing a system command must also remove copies left by older installers.
    cp "$system_bin/$program" "$legacy_bin/$program"
    ln -s "$program" "$legacy_bin/$short"
    ln -s "$system_bin/$program" "$system_bin/$short"
    run_installer >"$TMP/$short-second-install.log"
    [ ! -e "$legacy_bin/$program" ]
    [ ! -L "$legacy_bin/$short" ]
    [ ! -L "$system_bin/$short" ]
    grep -q 'Reusing existing' "$TMP/$short-second-install.log"

    # Never silently overwrite an unrelated user command.
    printf '%s\n' '#!/bin/sh' 'exit 0' >"$legacy_bin/$short"
    chmod 755 "$legacy_bin/$short"
    cp "$legacy_bin/$short" "$system_bin/$short"
    run_installer >"$TMP/$short-conflict.log" 2>&1
    [ -x "$legacy_bin/$short" ]
    cmp "$legacy_bin/$short" "$system_bin/$short"
done

echo 'OK dashboards use the system bin directory, migrate legacy copies, and preserve commands on failure'
