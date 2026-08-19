#!/bin/bash
set -euo pipefail

SOURCE_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/scriptorium-tailscale-check.XXXXXX")
trap 'rm -rf -- "$TEST_ROOT"' EXIT HUP INT TERM

FAKE_BIN=$TEST_ROOT/bin
SYSTEM_ROOT=$TEST_ROOT/system-root
STATE=$TEST_ROOT/tailscale-active
SYSTEMD_STATE=$TEST_ROOT/systemd
SYSTEMCTL_LOG=$TEST_ROOT/systemctl.log
APT_LOG=$TEST_ROOT/apt.log
UP_LOG=$TEST_ROOT/up.log
CURL_LOG=$TEST_ROOT/curl.log
mkdir -p "$FAKE_BIN" "$SYSTEM_ROOT/etc" "$SYSTEMD_STATE"

cat > "$TEST_ROOT/os-release" <<'EOF'
ID=debian
VERSION_CODENAME=trixie
EOF

cat > "$FAKE_BIN/curl" <<'EOF'
#!/bin/bash
set -euo pipefail
output=
url=
while (($#)); do
    case $1 in
        --output)
            shift
            output=$1
            ;;
        http*) url=$1 ;;
    esac
    shift
done
printf '%s\n' "$url" >> "$FAKE_CURL_LOG"
case $url in
    *.noarmor.gpg)
        printf '%s\n' fixture-signing-key > "$output"
        ;;
    *.tailscale-keyring.list)
        printf '%s\n' \
            '# Tailscale packages for debian trixie' \
            'deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/stable/debian trixie main' \
            > "$output"
        ;;
    *) exit 2 ;;
esac
EOF

cat > "$FAKE_BIN/install" <<'EOF'
#!/bin/bash
set -euo pipefail
args=()
while (($#)); do
    case $1 in
        -o|-g)
            shift
            ;;
        *) args+=("$1") ;;
    esac
    shift
done
exec /usr/bin/install "${args[@]}"
EOF

cat > "$TEST_ROOT/tailscale-template" <<'EOF'
#!/bin/bash
set -euo pipefail
case ${1:-} in
    status)
        if [[ -f $FAKE_TAILSCALE_STATE ]]; then
            printf '%s\n' '{"BackendState":"Running"}'
        else
            printf '%s\n' '{"BackendState":"NeedsLogin"}'
        fi
        ;;
    ip)
        [[ -f $FAKE_TAILSCALE_STATE ]] && printf '%s\n' '100.100.10.20'
        ;;
    up)
        printf '%s\n' "$*" >> "$FAKE_UP_LOG"
        auth_file=
        for argument in "$@"; do
            case $argument in
                --auth-key=file:*) auth_file=${argument#--auth-key=file:} ;;
            esac
        done
        if [[ -n ${FAKE_EXPECTED_AUTH_KEY:-} ]]; then
            [[ -n $auth_file ]]
            [[ $(<"$auth_file") == "$FAKE_EXPECTED_AUTH_KEY" ]]
        fi
        touch "$FAKE_TAILSCALE_STATE"
        ;;
    *) exit 2 ;;
esac
EOF

cat > "$FAKE_BIN/apt-get" <<'EOF'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >> "$FAKE_APT_LOG"
if [[ " $* " == *' install '* && " $* " == *' tailscale '* ]]; then
    cp "$FAKE_TAILSCALE_TEMPLATE" "$FAKE_BIN/tailscale"
    chmod 0755 "$FAKE_BIN/tailscale"
fi
EOF

cat > "$FAKE_BIN/systemctl" <<'EOF'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >> "$FAKE_SYSTEMCTL_LOG"
case ${1:-} in
    is-enabled) [[ -f $FAKE_SYSTEMD_STATE/enabled ]] ;;
    enable) touch "$FAKE_SYSTEMD_STATE/enabled" ;;
    is-active) [[ -f $FAKE_SYSTEMD_STATE/active ]] ;;
    start) touch "$FAKE_SYSTEMD_STATE/active" ;;
    *) exit 2 ;;
esac
EOF
chmod 0755 "$FAKE_BIN"/* "$TEST_ROOT/tailscale-template"

AUTH_FILE=$TEST_ROOT/auth.key
printf '%s\n' 'tskey-auth-fixture' > "$AUTH_FILE"
chmod 0600 "$AUTH_FILE"

export FAKE_APT_LOG="$APT_LOG"
export FAKE_BIN
export FAKE_CURL_LOG="$CURL_LOG"
export FAKE_EXPECTED_AUTH_KEY=tskey-auth-fixture
export FAKE_SYSTEMD_STATE="$SYSTEMD_STATE"
export FAKE_SYSTEMCTL_LOG="$SYSTEMCTL_LOG"
export FAKE_TAILSCALE_STATE="$STATE"
export FAKE_TAILSCALE_TEMPLATE="$TEST_ROOT/tailscale-template"
export FAKE_UP_LOG="$UP_LOG"

PATH="$FAKE_BIN:/usr/bin:/bin" \
SCRIPTORIUM_TAILSCALE_FAMILY=debian \
SCRIPTORIUM_TAILSCALE_FORCE_INSTALL=1 \
SCRIPTORIUM_TAILSCALE_OS_RELEASE="$TEST_ROOT/os-release" \
SCRIPTORIUM_TAILSCALE_SYSTEM_ROOT="$SYSTEM_ROOT" \
SCRIPTORIUM_TAILSCALE_TEST_MODE=1 \
TAILSCALE_AUTH_KEY_FILE="$AUTH_FILE" \
    "$SOURCE_ROOT/scripts/setup-tailscale.sh" > "$TEST_ROOT/first.out"

grep -q '^update$' "$APT_LOG"
grep -q '^install -y tailscale$' "$APT_LOG"
grep -q '/stable/debian/trixie.noarmor.gpg$' "$CURL_LOG"
grep -q '/stable/debian/trixie.tailscale-keyring.list$' "$CURL_LOG"
grep -q '^up --accept-dns=false --auth-key=file:' "$UP_LOG"
if grep -q 'tskey-auth-fixture' "$UP_LOG" "$TEST_ROOT/first.out"; then
    printf 'tailscale-bootstrap-check: auth key leaked into output or argv log\n' >&2
    exit 1
fi
grep -q 'Tailscale connected at 100.100.10.20' "$TEST_ROOT/first.out"
test -f "$SYSTEMD_STATE/enabled"
test -f "$SYSTEMD_STATE/active"
test "$(stat -c '%a' "$SYSTEM_ROOT/usr/share/keyrings/tailscale-archive-keyring.gpg")" = 644
test "$(stat -c '%a' "$SYSTEM_ROOT/etc/apt/sources.list.d/tailscale.list")" = 644

apt_lines=$(wc -l < "$APT_LOG")
curl_lines=$(wc -l < "$CURL_LOG")
up_lines=$(wc -l < "$UP_LOG")
service_mutations=$(grep -Ec '^(enable|start) ' "$SYSTEMCTL_LOG")
PATH="$FAKE_BIN:/usr/bin:/bin" \
SCRIPTORIUM_TAILSCALE_FAMILY=debian \
SCRIPTORIUM_TAILSCALE_OS_RELEASE="$TEST_ROOT/os-release" \
SCRIPTORIUM_TAILSCALE_SYSTEM_ROOT="$SYSTEM_ROOT" \
SCRIPTORIUM_TAILSCALE_TEST_MODE=1 \
TAILSCALE_AUTH_KEY_FILE="$AUTH_FILE" \
    "$SOURCE_ROOT/scripts/setup-tailscale.sh" > "$TEST_ROOT/second.out"
test "$(wc -l < "$APT_LOG")" -eq "$apt_lines"
test "$(wc -l < "$CURL_LOG")" -eq "$curl_lines"
test "$(wc -l < "$UP_LOG")" -eq "$up_lines"
test "$(grep -Ec '^(enable|start) ' "$SYSTEMCTL_LOG")" -eq "$service_mutations"
grep -q 'preserving its identity and preferences' "$TEST_ROOT/second.out"

rm -f "$STATE"
export FAKE_EXPECTED_AUTH_KEY=tskey-environment-fixture
PATH="$FAKE_BIN:/usr/bin:/bin" \
SCRIPTORIUM_TAILSCALE_FAMILY=debian \
SCRIPTORIUM_TAILSCALE_OS_RELEASE="$TEST_ROOT/os-release" \
SCRIPTORIUM_TAILSCALE_SYSTEM_ROOT="$SYSTEM_ROOT" \
SCRIPTORIUM_TAILSCALE_TEST_MODE=1 \
TAILSCALE_AUTH_KEY=tskey-environment-fixture \
    "$SOURCE_ROOT/scripts/setup-tailscale.sh" > "$TEST_ROOT/environment.out"
if grep -q 'tskey-environment-fixture' "$UP_LOG" "$TEST_ROOT/environment.out"; then
    printf 'tailscale-bootstrap-check: environment auth key leaked into output or argv log\n' >&2
    exit 1
fi

rm -f "$STATE"
export FAKE_EXPECTED_AUTH_KEY=
up_lines=$(wc -l < "$UP_LOG")
PATH="$FAKE_BIN:/usr/bin:/bin" \
SCRIPTORIUM_TAILSCALE_FAMILY=debian \
SCRIPTORIUM_TAILSCALE_OS_RELEASE="$TEST_ROOT/os-release" \
SCRIPTORIUM_TAILSCALE_SYSTEM_ROOT="$SYSTEM_ROOT" \
SCRIPTORIUM_TAILSCALE_TEST_MODE=1 \
    "$SOURCE_ROOT/scripts/setup-tailscale.sh" > "$TEST_ROOT/browser-login.out"
test "$(wc -l < "$UP_LOG")" -eq "$((up_lines + 1))"
test "$(tail -n 1 "$UP_LOG")" = 'up --accept-dns=false'
grep -q 'Open the login URL printed below' "$TEST_ROOT/browser-login.out"
grep -q 'Tailscale connected at 100.100.10.20' "$TEST_ROOT/browser-login.out"

grep -q 'choose_tailscale_component' "$SOURCE_ROOT/install.sh"
grep -q 'scripts/setup-tailscale.sh' "$SOURCE_ROOT/install.sh"
grep -q 'SimpleServe LAN and Tailscale transports are active' "$SOURCE_ROOT/install.sh"

printf 'OK Tailscale installs, enrolls securely, verifies, and preserves active nodes\n'
