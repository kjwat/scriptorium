#!/bin/sh
set -eu

SOURCE_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/setup-server-bootstrap.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT HUP INT TERM

export HOME=$TEST_ROOT/home
FIXTURE=$TEST_ROOT/website-source
TARGET=$HOME/website
mkdir -p "$HOME" "$FIXTURE/tools"

cat > "$HOME/setup-network-server" <<'EOF'
#!/bin/sh
printf '%s\n' "${1-none}" >> "$HOME/setup-network-server-calls"
EOF
chmod 755 "$HOME/setup-network-server"

cat >"$HOME/demote-server" <<'EOF'
#!/bin/sh
printf '%s\n' called >"$HOME/demote-server-called"
EOF
chmod 755 "$HOME/demote-server"

SCRIPTORIUM_SIMPLESERVE_ROLE_FILE=$HOME/missing-role \
    "$SOURCE_ROOT/setup-server.sh" --help >"$TEST_ROOT/help.out"
grep -q -- '--client' "$TEST_ROOT/help.out"
test ! -e "$TARGET"
test ! -e "$HOME/setup-network-server-calls"

printf '%s\n' server >"$HOME/simpleserve-role"
printf '%s\n' yes | WEBSITE_DIR=$TARGET WEBSITE_REPO_URL=$FIXTURE \
SCRIPTORIUM_NETWORK_SETUP=$HOME/setup-network-server \
SCRIPTORIUM_SERVER_DEMOTION=$HOME/demote-server \
SCRIPTORIUM_SIMPLESERVE_ROLE_FILE=$HOME/simpleserve-role \
    "$SOURCE_ROOT/setup-server.sh" >"$TEST_ROOT/demote.out"
test -f "$HOME/demote-server-called"
test ! -e "$TARGET"
test ! -e "$HOME/setup-network-server-calls"
printf '%s\n' client >"$HOME/simpleserve-role"

cat > "$FIXTURE/tools/setup_server.sh" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" > "$HOME/setup-server-arguments"
git -C "$HOME/website" rev-parse --short HEAD > "$HOME/setup-server-head"
EOF
chmod 755 "$FIXTURE/tools/setup_server.sh"
git -C "$FIXTURE" init -q
git -C "$FIXTURE" config user.name 'Website bootstrap test'
git -C "$FIXTURE" config user.email test@example.invalid
git -C "$FIXTURE" add tools/setup_server.sh
git -C "$FIXTURE" commit -qm initial

WEBSITE_DIR=$TARGET WEBSITE_REPO_URL=$FIXTURE \
SCRIPTORIUM_NETWORK_SETUP=$HOME/setup-network-server \
SCRIPTORIUM_SIMPLESERVE_ROLE_FILE=$HOME/simpleserve-role \
    "$SOURCE_ROOT/setup-server.sh" --no-public-check --non-interactive

test -d "$TARGET/.git"
grep -qx -- '--no-public-check' "$HOME/setup-server-arguments"
grep -qx -- '--non-interactive' "$HOME/setup-server-arguments"
test "$(cat "$HOME/setup-server-head")" = "$(git -C "$FIXTURE" rev-parse --short HEAD)"

printf '%s\n' updated > "$FIXTURE/version"
git -C "$FIXTURE" add version
git -C "$FIXTURE" commit -qm update
rm -f "$HOME/demote-server-called"
printf '%s\n' server >"$HOME/simpleserve-role"
WEBSITE_DIR=$TARGET WEBSITE_REPO_URL=$FIXTURE \
SCRIPTORIUM_NETWORK_SETUP=$HOME/setup-network-server \
SCRIPTORIUM_SIMPLESERVE_ROLE_FILE=$HOME/simpleserve-role \
    "$SOURCE_ROOT/setup-server.sh" --verify-only
test "$(cat "$HOME/setup-server-head")" = "$(git -C "$FIXTURE" rev-parse --short HEAD)"
test ! -e "$HOME/demote-server-called"

printf '%s\n' dirty > "$TARGET/local-change"
if WEBSITE_DIR=$TARGET WEBSITE_REPO_URL=$FIXTURE \
    SCRIPTORIUM_NETWORK_SETUP=$HOME/setup-network-server \
    SCRIPTORIUM_SIMPLESERVE_ROLE_FILE=$HOME/simpleserve-role \
    "$SOURCE_ROOT/setup-server.sh" --verify-only > /dev/null 2>&1; then
    printf 'setup-server-bootstrap-check: dirty checkout was accepted\n' >&2
    exit 1
fi

test "$(sed -n '1p' "$HOME/setup-network-server-calls")" = none
test "$(sed -n '2p' "$HOME/setup-network-server-calls")" = --verify-only
test "$(wc -l < "$HOME/setup-network-server-calls")" -eq 2

printf 'OK setup-server offers safe demotion before promoting, updating, delegating, or touching dirty checkouts\n'
