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

# Reject user-local destinations before cloning or building anything.
for local_destination in bin data; do
    test_bindir=$TMP/system-bin
    test_datadir=$TMP/system-data
    case "$local_destination" in
        bin) test_bindir=$HOME/.local/bin ;;
        data) test_datadir=$HOME/.local/share/simplesuite ;;
    esac
    if SIMPLESUITE_DIR="$TMP/rejected-checkout" \
       SIMPLESUITE_SYSTEM_BIN_DIR="$test_bindir" \
       SIMPLESUITE_SYSTEM_DATA_DIR="$test_datadir" \
        "$ROOT/scripts/install-simplesuite.sh" \
        >"$TMP/rejected-$local_destination.log" 2>&1; then
        echo 'missing-program-check: a user-local destination was accepted' >&2
        exit 1
    fi
    [ ! -e "$TMP/rejected-checkout" ]
    grep -q 'refusing a user-local installation' "$TMP/rejected-$local_destination.log"
done

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
simplesuite_program_aliases() { printf '%s\n' clock:simpleclock note:simplenote save:simplesave vol:simplevol; }
simplesuite_programs() { printf '%s\n' simpleclock simplenote simplesave simplevol; }
EOF
printf '%s\n' \
    'BUILD_DIR := build' \
    '' \
    'simpleclock:' \
    '	mkdir -p $(BUILD_DIR)' \
    '	printf '\''%s\n'\'' '\''#!/bin/sh'\'' '\''exit 0'\'' > $(BUILD_DIR)/simpleclock' \
    '	chmod 755 $(BUILD_DIR)/simpleclock' > Makefile
printf '%s\n' '#!/bin/sh' '# effects helper fixture' 'exit 0' >simplevol-audio
chmod 644 simplevol-audio
printf '%s\n' 'SimpleVol documentation fixture' >SIMPLEVOL.md
cat >>Makefile <<'EOF'

simplenote:
	mkdir -p $(BUILD_DIR)
	printf '%s\n' '#!/bin/sh' 'exit 0' > $(BUILD_DIR)/simplenote
	chmod 755 $(BUILD_DIR)/simplenote

simplesave:
	mkdir -p $(BUILD_DIR)
	printf '%s\n' '#!/bin/sh' 'exit 0' > $(BUILD_DIR)/simplesave
	chmod 755 $(BUILD_DIR)/simplesave

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
SIMPLESUITE_SYSTEM_DATA_DIR="$TMP/system-data" \
PATH="$TMP/test-bin:$PATH" \
    "$ROOT/scripts/install-simplesuite.sh" >"$TMP/install.log"

[ -x "$TMP/system-bin/simpleclock" ]
[ ! -e "$HOME/.local/bin/simpleclock" ]
[ "$(cat "$HOME/.local/bin/simplecal")" = preserved ]
[ ! -e "$TMP/system-bin/simplewords" ]
cmp "$SOURCE/uninstall.sh" "$TMP/system-bin/simplesuite-uninstall"
cmp "$SOURCE/program-manifest.sh" "$TMP/system-data/program-manifest.sh"
grep -qx 'vol simplevol' "$TMP/system-data/command-abbreviations"
grep -q "replaced: $TMP/system-bin/simpleclock" "$TMP/install.log"

# Adding notes to an existing install also refreshes the uninstall payload and
# both manifests, and removes an older user binary and short-command symlink.
printf '%s\n' stale >"$HOME/.local/bin/simplenote"
ln -s simplenote "$HOME/.local/bin/note"
ln -s "$TMP/system-bin/simplenote" "$TMP/system-bin/note"
SIMPLESUITE_REPO_URL="$ORIGIN" \
SIMPLESUITE_DIR="$TMP/checkout" \
SIMPLESUITE_NETWORK_ROLE=none \
SIMPLESUITE_PROGRAM_FILTER=simplenote \
SIMPLESUITE_INSTALL_PACKAGES=0 \
SIMPLESUITE_SYSTEM_BIN_DIR="$TMP/system-bin" \
SIMPLESUITE_SYSTEM_DATA_DIR="$TMP/system-data" \
PATH="$TMP/test-bin:$PATH" \
    "$ROOT/scripts/install-simplesuite.sh" >"$TMP/note-install.log"
[ -x "$TMP/system-bin/simplenote" ]
[ ! -e "$HOME/.local/bin/simplenote" ]
[ ! -L "$HOME/.local/bin/note" ]
[ ! -L "$TMP/system-bin/note" ]
cmp "$SOURCE/uninstall.sh" "$TMP/system-bin/simplesuite-uninstall"
cmp "$SOURCE/program-manifest.sh" "$TMP/system-data/program-manifest.sh"
grep -qx 'note simplenote' "$TMP/system-data/command-abbreviations"
[ "$(cat "$HOME/.local/bin/simplecal")" = preserved ]
[ ! -e "$TMP/system-bin/simplewords" ]

# A partial SimpleSave installation uses the same manifest and system paths.
SIMPLESUITE_REPO_URL="$ORIGIN" \
SIMPLESUITE_DIR="$TMP/checkout" \
SIMPLESUITE_NETWORK_ROLE=none \
SIMPLESUITE_PROGRAM_FILTER=simplesave \
SIMPLESUITE_INSTALL_PACKAGES=0 \
SIMPLESUITE_SYSTEM_BIN_DIR="$TMP/system-bin" \
SIMPLESUITE_SYSTEM_DATA_DIR="$TMP/system-data" \
PATH="$TMP/test-bin:$PATH" \
    "$ROOT/scripts/install-simplesuite.sh" >"$TMP/save-install.log"
[ -x "$TMP/system-bin/simplesave" ]
[ ! -e "$HOME/.local/bin/simplesave" ]
grep -qx 'save simplesave' "$TMP/system-data/command-abbreviations"
cmp "$SOURCE/uninstall.sh" "$TMP/system-bin/simplesuite-uninstall"

if [ "$(uname -s)" = Linux ]; then
    printf '%s\n' stale >"$HOME/.local/bin/simplevol"
    printf '%s\n' stale >"$HOME/.local/bin/simplevol-audio"
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
    [ ! -e "$HOME/.local/bin/simplevol" ]
    [ ! -e "$HOME/.local/bin/simplevol-audio" ]
    cmp "$SOURCE/simplevol-audio" "$TMP/system-bin/simplevol-audio"
    cmp "$SOURCE/SIMPLEVOL.md" "$TMP/system-data/SIMPLEVOL.md"
    cmp "$TMP/checkout/build/simplevol-meter.so" "$TMP/system-data/simplevol-meter.so"
    [ "$(cat "$HOME/.local/bin/simplecal")" = preserved ]
    [ ! -e "$TMP/system-bin/simplewords" ]
fi

echo 'OK Scriptorium builds and installs only a missing master-list program'
