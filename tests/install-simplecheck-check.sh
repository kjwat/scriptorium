#!/bin/sh
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/scriptorium-simplecheck-install.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

export HOME="$TMP/home"
mkdir -p "$HOME"

"$ROOT/scripts/install-simplecheck.sh" >"$TMP/first-install.log"

[ -x "$HOME/.local/bin/simplecheck" ]
[ -L "$HOME/.local/bin/check" ]
[ "$(readlink "$HOME/.local/bin/check")" = simplecheck ]
[ "$(PATH="$HOME/.local/bin:$PATH" command -v check)" = \
  "$HOME/.local/bin/check" ]
[ "$(realpath "$HOME/.local/bin/check")" = \
  "$HOME/.local/bin/simplecheck" ]

# A repeated install must keep the managed command alias intact.
"$ROOT/scripts/install-simplecheck.sh" >"$TMP/second-install.log"
[ -L "$HOME/.local/bin/check" ]
[ "$(readlink "$HOME/.local/bin/check")" = simplecheck ]

# Never silently overwrite an unrelated user command.
rm "$HOME/.local/bin/check"
printf '%s\n' '#!/bin/sh' 'exit 0' >"$HOME/.local/bin/check"
chmod 755 "$HOME/.local/bin/check"
if "$ROOT/scripts/install-simplecheck.sh" >"$TMP/conflict.log" 2>&1; then
    echo 'install-simplecheck check: unrelated check command was overwritten' >&2
    exit 1
fi
grep -q 'Refusing to replace unrelated check command' "$TMP/conflict.log"

echo 'OK SimpleCheck installs an immediate, idempotent check command alias'
