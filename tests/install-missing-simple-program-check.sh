#!/bin/sh
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/scriptorium-missing-program.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

SOURCE=$TMP/source
ORIGIN=$TMP/origin.git
export HOME=$TMP/home
mkdir -p "$SOURCE" "$HOME/.local/bin"

printf '%s\n' preserved >"$HOME/.local/bin/simplecal"
chmod 755 "$HOME/.local/bin/simplecal"

cd "$SOURCE"
git init -q
git config user.email test@example.invalid
git config user.name test
printf '%s\n' '# fixture' > README
printf '%s\n' '#!/bin/sh' 'exit 0' > checkdeps.sh
printf '%s\n' '#!/bin/sh' 'exit 0' > uninstall.sh
chmod 755 checkdeps.sh uninstall.sh
cat >program-manifest.sh <<'EOF'
simplesuite_program_aliases() { printf '%s\n' clock:simpleclock; }
simplesuite_programs() { printf '%s\n' simpleclock; }
EOF
printf '%s\n' \
    'BUILD_DIR := build' \
    '' \
    'simpleclock:' \
    '	mkdir -p $(BUILD_DIR)' \
    '	printf '\''%s\n'\'' '\''#!/bin/sh'\'' '\''exit 0'\'' > $(BUILD_DIR)/simpleclock' \
    '	chmod 755 $(BUILD_DIR)/simpleclock' > Makefile
git add .
git commit -qm fixture
git clone -q --bare "$SOURCE" "$ORIGIN"

SIMPLESUITE_REPO_URL="$ORIGIN" \
SIMPLESUITE_DIR="$TMP/checkout" \
SIMPLESUITE_NETWORK_ROLE=none \
SIMPLESUITE_PROGRAM_FILTER=simpleclock \
SIMPLESUITE_INSTALL_PACKAGES=0 \
    "$ROOT/scripts/install-simplesuite.sh" >"$TMP/install.log"

[ -x "$HOME/.local/bin/simpleclock" ]
[ "$(cat "$HOME/.local/bin/simplecal")" = preserved ]
[ ! -e "$HOME/.local/bin/simplewords" ]
grep -q 'installed missing program: simpleclock' "$TMP/install.log"

echo 'OK Scriptorium builds and installs only a missing master-list program'
