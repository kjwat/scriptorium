#!/bin/sh
set -eu

SOURCE_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/setup-server-bootstrap.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT HUP INT TERM

export HOME=$TEST_ROOT/home
FIXTURE=$TEST_ROOT/website-source
TARGET=$HOME/website
mkdir -p "$HOME" "$FIXTURE/tools"

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
    "$SOURCE_ROOT/setup-server.sh" --no-public-check --non-interactive

test -d "$TARGET/.git"
grep -qx -- '--no-public-check' "$HOME/setup-server-arguments"
grep -qx -- '--non-interactive' "$HOME/setup-server-arguments"
test "$(cat "$HOME/setup-server-head")" = "$(git -C "$FIXTURE" rev-parse --short HEAD)"

printf '%s\n' updated > "$FIXTURE/version"
git -C "$FIXTURE" add version
git -C "$FIXTURE" commit -qm update
WEBSITE_DIR=$TARGET WEBSITE_REPO_URL=$FIXTURE \
    "$SOURCE_ROOT/setup-server.sh" --verify-only
test "$(cat "$HOME/setup-server-head")" = "$(git -C "$FIXTURE" rev-parse --short HEAD)"

printf '%s\n' dirty > "$TARGET/local-change"
if WEBSITE_DIR=$TARGET WEBSITE_REPO_URL=$FIXTURE \
    "$SOURCE_ROOT/setup-server.sh" --verify-only > /dev/null 2>&1; then
    printf 'setup-server-bootstrap-check: dirty checkout was accepted\n' >&2
    exit 1
fi

printf 'OK setup-server clones, updates, delegates, and protects dirty checkouts\n'
