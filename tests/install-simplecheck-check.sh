#!/bin/sh
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/scriptorium-simplecheck-install.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

export HOME="$TMP/home"
mkdir -p "$HOME"

"$ROOT/scripts/install-simplecheck.sh" >"$TMP/first-install.log"

[ -x "$HOME/.local/bin/simplecheck" ]
[ ! -e "$HOME/.local/bin/check" ]

# A repeated install reuses the canonical binary and creates no executable alias.
"$ROOT/scripts/install-simplecheck.sh" >"$TMP/second-install.log"
[ ! -e "$HOME/.local/bin/check" ]
grep -q 'Reusing existing' "$TMP/second-install.log"

# Never silently overwrite an unrelated user command.
printf '%s\n' '#!/bin/sh' 'exit 0' >"$HOME/.local/bin/check"
chmod 755 "$HOME/.local/bin/check"
if "$ROOT/scripts/install-simplecheck.sh" >"$TMP/conflict.log" 2>&1; then
    echo 'install-simplecheck check: unrelated check command was overwritten' >&2
    exit 1
fi
grep -q 'Refusing to replace unrelated check command' "$TMP/conflict.log"

echo 'OK SimpleCheck installs only its canonical binary and reuses it idempotently'
