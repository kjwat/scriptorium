#!/bin/sh
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/scriptorium-missing-program.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

SOURCE=$TMP/source
ORIGIN=$TMP/origin.git
export HOME=$TMP/home
mkdir -p "$SOURCE" "$HOME/.local/bin" "$TMP/system-bin" "$TMP/test-bin"
printf '%s\n' '#!/bin/sh' 'exec "$@"' >"$TMP/test-bin/sudo"
chmod 755 "$TMP/test-bin/sudo"

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
simplesuite_program_aliases() { printf '%s\n' clock:simpleclock vol:simplevol; }
simplesuite_programs() { printf '%s\n' simpleclock simplevol; }
EOF
printf '%s\n' \
    'BUILD_DIR := build' \
    '' \
    'simpleclock:' \
    '	mkdir -p $(BUILD_DIR)' \
    '	printf '\''%s\n'\'' '\''#!/bin/sh'\'' '\''exit 0'\'' > $(BUILD_DIR)/simpleclock' \
    '	chmod 755 $(BUILD_DIR)/simpleclock' > Makefile
printf '%s\n' '#!/bin/sh' '# effects helper fixture' 'exit 0' >simplevol-audio
chmod 755 simplevol-audio
printf '%s\n' 'SimpleVol documentation fixture' >SIMPLEVOL.md
cat >>Makefile <<'EOF'

simplevol:
	mkdir -p $(BUILD_DIR)
	printf '%s\n' '#!/bin/sh' 'exit 0' > $(BUILD_DIR)/simplevol
	chmod 755 $(BUILD_DIR)/simplevol
	printf '%s\n' 'meter fixture' > $(BUILD_DIR)/simplevol-meter.so
EOF
printf '%s\n' /build/ >.gitignore
git add .
git commit -qm fixture
git clone -q --bare "$SOURCE" "$ORIGIN"

SIMPLESUITE_REPO_URL="$ORIGIN" \
SIMPLESUITE_DIR="$TMP/checkout" \
SIMPLESUITE_NETWORK_ROLE=none \
SIMPLESUITE_PROGRAM_FILTER=simpleclock \
SIMPLESUITE_INSTALL_PACKAGES=0 \
SIMPLESUITE_SYSTEM_BIN_DIR="$TMP/system-bin" \
PATH="$TMP/test-bin:$PATH" \
    "$ROOT/scripts/install-simplesuite.sh" >"$TMP/install.log"

[ -x "$TMP/system-bin/simpleclock" ]
[ ! -e "$HOME/.local/bin/simpleclock" ]
[ "$(cat "$HOME/.local/bin/simplecal")" = preserved ]
[ ! -e "$TMP/system-bin/simplewords" ]
grep -q "replaced: $TMP/system-bin/simpleclock" "$TMP/install.log"

if [ "$(uname -s)" = Linux ]; then
    SIMPLESUITE_REPO_URL="$ORIGIN" \
    SIMPLESUITE_DIR="$TMP/checkout" \
    SIMPLESUITE_NETWORK_ROLE=none \
    SIMPLESUITE_PROGRAM_FILTER=simplevol \
    SIMPLESUITE_INSTALL_PACKAGES=0 \
    SIMPLESUITE_SYSTEM_BIN_DIR="$TMP/system-bin" \
    SIMPLESUITE_SYSTEM_DATA_DIR="$TMP/system-data" \
    PATH="$TMP/test-bin:$PATH" \
        "$ROOT/scripts/install-simplesuite.sh" >"$TMP/effects-install.log"
    [ -x "$TMP/system-bin/simplevol" ]
    [ -x "$TMP/system-bin/simplevol-audio" ]
    cmp "$SOURCE/simplevol-audio" "$TMP/system-bin/simplevol-audio"
    cmp "$SOURCE/SIMPLEVOL.md" "$TMP/system-data/SIMPLEVOL.md"
    cmp "$TMP/checkout/build/simplevol-meter.so" "$TMP/system-data/simplevol-meter.so"
    [ "$(cat "$HOME/.local/bin/simplecal")" = preserved ]
    [ ! -e "$TMP/system-bin/simplewords" ]
fi

echo 'OK Scriptorium builds and installs only a missing master-list program'
