#!/usr/bin/env bash
set -euo pipefail

REPOSITORY_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/server-provisioning-check.XXXXXX")
trap 'rm -rf -- "$TEST_ROOT"' EXIT HUP INT TERM

PYTHONDONTWRITEBYTECODE=1 python3 "$REPOSITORY_ROOT/tests/server-provisioning-check.py"
bash -n "$REPOSITORY_ROOT/scripts/setup-website-server.sh"
sh -n "$REPOSITORY_ROOT/scripts/server/check_server.sh" \
    "$REPOSITORY_ROOT/scripts/server/platform.sh"

function_definition=$(sed -n \
    '/^cloudflared_supports_token_file() {$/,/^}$/p' \
    "$REPOSITORY_ROOT/scripts/setup-website-server.sh")
[[ -n $function_definition ]]
eval "$function_definition"

cat >"$TEST_ROOT/cloudflared-with-token-file" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ $* == 'tunnel run --help' ]]
printf '%s\n' '  --token-file value  Read a protected tunnel token file'
for ((line = 0; line < 20000; line++)); do
    printf 'additional help line %05d with enough text to fill the pipe buffer\n' "$line"
done
EOF
cat >"$TEST_ROOT/cloudflared-without-token-file" <<'EOF'
#!/bin/sh
printf '%s\n' 'cloudflared tunnel run help without the required capability'
EOF
chmod 755 "$TEST_ROOT/cloudflared-with-token-file" \
    "$TEST_ROOT/cloudflared-without-token-file"

WORK_DIR=$TEST_ROOT/with-capability
mkdir -p "$WORK_DIR"
CLOUDFLARED_BIN=$TEST_ROOT/cloudflared-with-token-file
cloudflared_supports_token_file
WORK_DIR=$TEST_ROOT/without-capability
mkdir -p "$WORK_DIR"
CLOUDFLARED_BIN=$TEST_ROOT/cloudflared-without-token-file
if cloudflared_supports_token_file; then
    printf 'server-provisioning-check: cloudflared without --token-file was accepted\n' >&2
    exit 1
fi

state_definition=$(sed -n \
    '/^resolve_state_backup() {$/,/^}$/p' \
    "$REPOSITORY_ROOT/scripts/setup-website-server.sh")
[[ -n $state_definition ]]
eval "$state_definition"
state_backup=$TEST_ROOT/state-backup
mkdir -p "$state_backup/cloudflared"
printf '%s\n' store >"$state_backup/store.env"
printf '%s\n' token >"$state_backup/cloudflared/token"
printf '%s\n' api-token >"$state_backup/cloudflared/api-token"
printf '%s\n' editing-api-token >"$state_backup/cloudflared/editing-api-token"
(
    STATE_BACKUP_DIR=$state_backup
    STORE_ENV_IMPORT=
    ORDERS_DB_IMPORT=
    CLOUDFLARE_CONFIG_IMPORT=
    CLOUDFLARE_CREDENTIALS_IMPORT=
    CLOUDFLARE_TOKEN_INPUT=
    CLOUDFLARE_API_TOKEN_INPUT=
    CLOUDFLARE_EDITING_API_TOKEN_INPUT=
    resolve_state_backup
    [[ $STORE_ENV_IMPORT == "$state_backup/store.env" ]]
    [[ $CLOUDFLARE_TOKEN_INPUT == "$state_backup/cloudflared/token" ]]
    [[ $CLOUDFLARE_API_TOKEN_INPUT == "$state_backup/cloudflared/api-token" ]]
    [[ $CLOUDFLARE_EDITING_API_TOKEN_INPUT == "$state_backup/cloudflared/editing-api-token" ]]
    [[ -z $CLOUDFLARE_CONFIG_IMPORT ]]
)
printf '%s\n' config >"$state_backup/cloudflared/config.yml"
printf '%s\n' credentials >"$state_backup/cloudflared/credentials.json"
(
    STATE_BACKUP_DIR=$state_backup
    STORE_ENV_IMPORT=
    ORDERS_DB_IMPORT=
    CLOUDFLARE_CONFIG_IMPORT=
    CLOUDFLARE_CREDENTIALS_IMPORT=
    CLOUDFLARE_TOKEN_INPUT=
    CLOUDFLARE_API_TOKEN_INPUT=
    CLOUDFLARE_EDITING_API_TOKEN_INPUT=
    resolve_state_backup
    [[ $CLOUDFLARE_CONFIG_IMPORT == "$state_backup/cloudflared/config.yml" ]]
    [[ $CLOUDFLARE_CREDENTIALS_IMPORT == "$state_backup/cloudflared/credentials.json" ]]
    [[ -z $CLOUDFLARE_TOKEN_INPUT ]]
    [[ $CLOUDFLARE_API_TOKEN_INPUT == "$state_backup/cloudflared/api-token" ]]
    [[ $CLOUDFLARE_EDITING_API_TOKEN_INPUT == "$state_backup/cloudflared/editing-api-token" ]]
)
rm "$state_backup/cloudflared/editing-api-token"
(
    STATE_BACKUP_DIR=$state_backup
    CLOUDFLARE_EDITING_API_TOKEN_INPUT=
    resolve_state_backup
    [[ -z $CLOUDFLARE_EDITING_API_TOKEN_INPUT ]]
)

# Reuse the saved credentials and install/restore a missing business token
# without ever writing the literary site's credential.
(
    for function_name in prepare_cloudflare_api_token validate_cloudflare_api_token; do
        eval "$(sed -n "/^${function_name}() {$/,/^}$/p" \
            "$REPOSITORY_ROOT/scripts/setup-website-server.sh")"
    done
    die() { printf '%s\n' "$*" >&2; exit 1; }
    sudo() { "$@"; }
    ensure_root_directory() { :; }
    install_root_file_if_changed() {
        [[ $2 != "$CLOUDFLARE_API_TOKEN_TARGET" ]] || die 'literary token was rewritten'
        install -m "$3" "$1" "$2"
        printf -v "$4" '%s' 1
    }
    WORK_DIR=$TEST_ROOT/token-check
    mkdir -m 700 "$WORK_DIR"
    SITE_USER=$(id -un)
    SITE_GROUP=$(id -gn)
    NON_INTERACTIVE=1
    CLOUDFLARE_API_TOKEN_TARGET=$WORK_DIR/literary.token
    CLOUDFLARE_EDITING_API_TOKEN_TARGET=$WORK_DIR/editing.token
    CLOUDFLARE_API_TOKEN_INPUT=
    CLOUDFLARE_EDITING_API_TOKEN_INPUT=
    CLOUDFLARE_API_TOKEN_ENV=
    CLOUDFLARE_EDITING_API_TOKEN_ENV=
    printf '%s\n' literary-fixture >"$CLOUDFLARE_API_TOKEN_TARGET"
    printf '%s\n' editing-fixture >"$CLOUDFLARE_EDITING_API_TOKEN_TARGET"
    chmod 600 "$CLOUDFLARE_API_TOKEN_TARGET" "$CLOUDFLARE_EDITING_API_TOKEN_TARGET"
    prepare_cloudflare_api_token >"$WORK_DIR/output"
    prepare_cloudflare_api_token editing >>"$WORK_DIR/output"
    cmp "$CLOUDFLARE_API_TOKEN_TARGET" "$WORK_DIR/cloudflare-management-api.token"
    cmp "$CLOUDFLARE_EDITING_API_TOKEN_TARGET" "$WORK_DIR/cloudflare-editing-api.token"
    ! grep -q 'literary-fixture\|editing-fixture' "$WORK_DIR/output"
    rm "$CLOUDFLARE_EDITING_API_TOKEN_TARGET"
    CLOUDFLARE_EDITING_API_TOKEN_ENV=
    if (prepare_cloudflare_api_token editing) >"$WORK_DIR/missing.out" 2>&1; then
        die 'missing business credential silently reused the literary token'
    fi
    grep -q -- '--editing-api-token-file' "$WORK_DIR/missing.out"
    printf '%s\n' restored-editing-fixture >"$WORK_DIR/restore.token"
    CLOUDFLARE_EDITING_API_TOKEN_INPUT=$WORK_DIR/restore.token
    prepare_cloudflare_api_token editing >>"$WORK_DIR/output"
    cmp "$WORK_DIR/restore.token" "$CLOUDFLARE_EDITING_API_TOKEN_TARGET"
    [[ $(cat "$CLOUDFLARE_API_TOKEN_TARGET") == literary-fixture ]]
)

# Public verification must fail when either business address is unavailable.
(
    eval "$(sed -n '/^check_public_site() {$/,/^}$/p' \
        "$REPOSITORY_ROOT/scripts/setup-website-server.sh")"
    die() { printf '%s\n' "$*" >&2; exit 1; }
    sleep() { :; }
    curl() {
        local url=${!#}
        printf '%s\n' "$url" >>"$TEST_ROOT/public-check.urls"
        case $url in
            */_store/health) printf '%s' '{"status":"ok"}' ;;
            https://www.watlingtonediting.com/) printf '%s' "$FIXTURE_EDITING_WWW_STATUS" ;;
            *) printf '%s' 200 ;;
        esac
    }
    PUBLIC_ORIGIN=https://keelanwatlington.com
    SITE_ADDRESS=:8080
    CLOUDFLARE_EDITING_APEX_HOSTNAME=watlingtonediting.com
    CLOUDFLARE_EDITING_WWW_HOSTNAME=www.watlingtonediting.com
    FIXTURE_EDITING_WWW_STATUS=200
    check_public_site >"$TEST_ROOT/public-check.out"
    grep -qx 'https://watlingtonediting.com/' "$TEST_ROOT/public-check.urls"
    grep -qx 'https://www.watlingtonediting.com/' "$TEST_ROOT/public-check.urls"
    FIXTURE_EDITING_WWW_STATUS=503
    if (check_public_site) >"$TEST_ROOT/public-check-failure.out" 2>&1; then
        die 'public verification accepted a broken business hostname'
    fi
)

platform_script=$REPOSITORY_ROOT/scripts/server/platform.sh
# shellcheck source=../scripts/server/platform.sh
. "$platform_script"
release_file=$TEST_ROOT/os-release
printf '%s\n' 'ID="debian"' >"$release_file"
[[ $(WEBSITE_HOST_OS=Linux WEBSITE_OS_RELEASE=$release_file website_detect_family) == debian ]]
printf '%s\n' 'ID="fedora"' >"$release_file"
[[ $(WEBSITE_HOST_OS=Linux WEBSITE_OS_RELEASE=$release_file website_detect_family) == fedora ]]
printf '%s\n' 'ID="endeavouros"' 'ID_LIKE="arch"' >"$release_file"
[[ $(WEBSITE_HOST_OS=Linux WEBSITE_OS_RELEASE=$release_file website_detect_family) == arch ]]
printf '%s\n' 'ID="alpine"' >"$release_file"
[[ $(WEBSITE_HOST_OS=Linux WEBSITE_OS_RELEASE=$release_file website_detect_family) == alpine ]]
printf '%s\n' 'ID="void"' >"$release_file"
[[ $(WEBSITE_HOST_OS=Linux WEBSITE_OS_RELEASE=$release_file website_detect_family) == void ]]
printf '%s\n' 'ID="opensuse-tumbleweed"' 'ID_LIKE="opensuse suse"' >"$release_file"
[[ $(WEBSITE_HOST_OS=Linux WEBSITE_OS_RELEASE=$release_file website_detect_family) == suse ]]
[[ $(WEBSITE_HOST_OS=FreeBSD website_detect_family) == freebsd ]]
[[ $(WEBSITE_HOST_OS=Darwin website_detect_family) == macos ]]

if grep -Fq 'tools/setup_server.sh' "$REPOSITORY_ROOT/setup-server.sh"; then
    printf 'server-provisioning-check: setup-server still delegates to the website installer\n' >&2
    exit 1
fi
for authority_consumer in "$REPOSITORY_ROOT/setup-server.sh" \
                          "$REPOSITORY_ROOT/scripts/demote-server.sh" \
                          "$REPOSITORY_ROOT/simpletrident.c"; do
    if grep -Eq '/tools/(check_server|Caddyfile|backup_server_state|setup_server)' \
        "$authority_consumer"; then
        printf 'server-provisioning-check: website-owned provisioning remains in %s\n' \
            "$authority_consumer" >&2
        exit 1
    fi
done
grep -Fq -- '--zone-name "$CLOUDFLARE_APEX_HOSTNAME"' \
    "$REPOSITORY_ROOT/scripts/setup-website-server.sh"
for cloudflare_permission in 'Account / Cloudflare Tunnel / Edit' \
                             'Zone / Zone / Read' \
                             'Zone / DNS / Edit'; do
    grep -Fq "$cloudflare_permission" \
        "$REPOSITORY_ROOT/scripts/setup-website-server.sh"
done
printf 'OK Scriptorium owns website provisioning, detects cloudflared capabilities, and renders protected services\n'
