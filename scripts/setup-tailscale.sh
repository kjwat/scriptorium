#!/usr/bin/env bash
set -euo pipefail

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
FAMILY=${SCRIPTORIUM_TAILSCALE_FAMILY:-$("$ROOT/detect-platform.sh")}
TEST_MODE=${SCRIPTORIUM_TAILSCALE_TEST_MODE:-0}
FORCE_INSTALL=${SCRIPTORIUM_TAILSCALE_FORCE_INSTALL:-0}
SYSTEM_ROOT=${SCRIPTORIUM_TAILSCALE_SYSTEM_ROOT:-}
ACCEPT_DNS=${TAILSCALE_ACCEPT_DNS:-0}
AUTH_KEY=${TAILSCALE_AUTH_KEY:-}
AUTH_KEY_FILE=${TAILSCALE_AUTH_KEY_FILE:-}
HOSTNAME_OVERRIDE=${TAILSCALE_HOSTNAME:-}
unset TAILSCALE_AUTH_KEY

if [[ -n ${SCRIPTORIUM_TAILSCALE_OS_RELEASE:-} ]]; then
    OS_RELEASE=$SCRIPTORIUM_TAILSCALE_OS_RELEASE
else
    OS_RELEASE=$SYSTEM_ROOT/etc/os-release
fi

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/scriptorium-tailscale.XXXXXX")
chmod 0700 "$WORK_DIR"
cleanup() {
    rm -rf -- "$WORK_DIR"
}
trap cleanup EXIT INT TERM

die() {
    printf 'Tailscale setup: %s\n' "$*" >&2
    exit 1
}

run_as_root() {
    if [[ $TEST_MODE == 1 || $(id -u) -eq 0 ]]; then
        "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo "$@"
    else
        die "root privileges are required, but sudo is unavailable"
    fi
}

release_value() {
    local wanted=$1

    [[ -r $OS_RELEASE ]] || return 0
    awk -F= -v wanted="$wanted" '
        $1 == wanted {
            value = substr($0, index($0, "=") + 1)
            if (value ~ /^".*"$/ || value ~ /^\047.*\047$/)
                value = substr(value, 2, length(value) - 2)
            print tolower(value)
            exit
        }
    ' "$OS_RELEASE"
}

install_root_file_if_changed() {
    local source=$1 target=$2 mode=$3 installed_mode

    installed_mode=$(run_as_root stat -c '%a' "$target" 2>/dev/null || true)
    if [[ $installed_mode == "$mode" ]] && run_as_root cmp -s "$source" "$target"; then
        return 0
    fi
    run_as_root install -m "$mode" -o root -g root "$source" "$target"
}

install_tailscale_debian() {
    local distro codename id id_like ubuntu_codename version_codename
    local base key_target list_target expected_line
    local -a repository_lines=()

    [[ $FAMILY == debian ]] ||
        die "automatic package installation currently supports Debian and Ubuntu"
    id=$(release_value ID)
    id_like=$(release_value ID_LIKE)
    ubuntu_codename=$(release_value UBUNTU_CODENAME)
    version_codename=$(release_value VERSION_CODENAME)

    case $id in
        ubuntu)
            distro=ubuntu
            codename=${ubuntu_codename:-$version_codename}
            ;;
        debian)
            distro=debian
            codename=$version_codename
            ;;
        *)
            if [[ -n $ubuntu_codename ]] &&
               [[ " $id_like " == *" ubuntu "* || " $id_like " == *" debian "* ]]; then
                distro=ubuntu
                codename=$ubuntu_codename
            else
                die "automatic package installation does not know the official Tailscale repository for ${id:-this distribution}"
            fi
            ;;
    esac
    [[ $codename =~ ^[a-z0-9][a-z0-9-]*$ ]] ||
        die "could not determine a safe Debian/Ubuntu release codename"

    base=https://pkgs.tailscale.com/stable/$distro
    curl --fail --silent --show-error --location \
        --output "$WORK_DIR/tailscale-archive-keyring.gpg" \
        "$base/$codename.noarmor.gpg"
    curl --fail --silent --show-error --location \
        --output "$WORK_DIR/tailscale.list" \
        "$base/$codename.tailscale-keyring.list"
    [[ -s $WORK_DIR/tailscale-archive-keyring.gpg ]] ||
        die "the downloaded Tailscale signing key is empty"

    mapfile -t repository_lines < <(
        sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' \
            "$WORK_DIR/tailscale.list"
    )
    expected_line="deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] $base $codename main"
    ((${#repository_lines[@]} == 1)) && [[ ${repository_lines[0]} == "$expected_line" ]] ||
        die "the downloaded Tailscale repository definition was not recognized"

    key_target=$SYSTEM_ROOT/usr/share/keyrings/tailscale-archive-keyring.gpg
    list_target=$SYSTEM_ROOT/etc/apt/sources.list.d/tailscale.list
    run_as_root install -d -m 0755 \
        "$SYSTEM_ROOT/usr/share/keyrings" "$SYSTEM_ROOT/etc/apt/sources.list.d"
    install_root_file_if_changed \
        "$WORK_DIR/tailscale-archive-keyring.gpg" "$key_target" 644
    install_root_file_if_changed "$WORK_DIR/tailscale.list" "$list_target" 644
    run_as_root env DEBIAN_FRONTEND=noninteractive LC_ALL=C apt-get update
    run_as_root env DEBIAN_FRONTEND=noninteractive LC_ALL=C \
        apt-get install -y tailscale
    hash -r
}

tailscale_ipv4() {
    local address

    [[ $("$TAILSCALE_BIN" status --json 2>/dev/null |
        python3 -c 'import json, sys; print(json.load(sys.stdin).get("BackendState", ""))' \
        2>/dev/null) == Running ]] || return 1
    address=$("$TAILSCALE_BIN" ip -4 2>/dev/null | sed -n '1p')
    case $address in
        100.6[4-9].* | 100.[7-9][0-9].* | 100.1[01][0-9].* | 100.12[0-7].*)
            printf '%s\n' "$address"
            ;;
        *) return 1 ;;
    esac
}

case $TEST_MODE in
    0 | 1) ;;
    *) die "SCRIPTORIUM_TAILSCALE_TEST_MODE must be 0 or 1" ;;
esac
case $FORCE_INSTALL in
    0) ;;
    1)
        [[ $TEST_MODE == 1 ]] ||
            die "SCRIPTORIUM_TAILSCALE_FORCE_INSTALL is only available in test mode"
        ;;
    *) die "SCRIPTORIUM_TAILSCALE_FORCE_INSTALL must be 0 or 1" ;;
esac
case $ACCEPT_DNS in
    0 | false | no) ACCEPT_DNS=false ;;
    1 | true | yes) ACCEPT_DNS=true ;;
    *) die "TAILSCALE_ACCEPT_DNS must be 0 or 1" ;;
esac
[[ -z $SYSTEM_ROOT || $TEST_MODE == 1 ]] ||
    die "SCRIPTORIUM_TAILSCALE_SYSTEM_ROOT is only available in test mode"
[[ -z $AUTH_KEY || -z $AUTH_KEY_FILE ]] ||
    die "use only one of TAILSCALE_AUTH_KEY and TAILSCALE_AUTH_KEY_FILE"
if [[ -n $HOSTNAME_OVERRIDE ]]; then
    [[ ${#HOSTNAME_OVERRIDE} -le 63 &&
       $HOSTNAME_OVERRIDE =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] ||
        die "TAILSCALE_HOSTNAME must be a valid hostname label"
fi

if [[ $FORCE_INSTALL == 1 ]] || ! command -v tailscale >/dev/null 2>&1; then
    printf 'Installing Tailscale from its signed official repository...\n'
    install_tailscale_debian
fi
TAILSCALE_BIN=$(command -v tailscale 2>/dev/null || true)
[[ -n $TAILSCALE_BIN ]] || die "the tailscale command is unavailable after installation"
command -v python3 >/dev/null 2>&1 || die "python3 is required to verify Tailscale state"
command -v systemctl >/dev/null 2>&1 ||
    die "automatic tailscaled service setup currently requires systemd"

if ! run_as_root systemctl is-enabled --quiet tailscaled.service 2>/dev/null; then
    run_as_root systemctl enable tailscaled.service
fi
if ! run_as_root systemctl is-active --quiet tailscaled.service; then
    run_as_root systemctl start tailscaled.service
fi
run_as_root systemctl is-active --quiet tailscaled.service ||
    die "tailscaled.service did not become active"

connected_ip=$(tailscale_ipv4 || true)
if [[ -n $connected_ip ]]; then
    printf 'Tailscale already connected at %s; preserving its identity and preferences.\n' \
        "$connected_ip"
    exit 0
fi

up_args=(up "--accept-dns=$ACCEPT_DNS")
if [[ -n $HOSTNAME_OVERRIDE ]]; then
    up_args+=("--hostname=$HOSTNAME_OVERRIDE")
fi
if [[ -n $AUTH_KEY ]]; then
    [[ $AUTH_KEY != *[[:space:]]* ]] || die "TAILSCALE_AUTH_KEY contains whitespace"
    printf '%s\n' "$AUTH_KEY" > "$WORK_DIR/auth.key"
    chmod 0600 "$WORK_DIR/auth.key"
    up_args+=("--auth-key=file:$WORK_DIR/auth.key")
elif [[ -n $AUTH_KEY_FILE ]]; then
    [[ $AUTH_KEY_FILE == /* ]] || die "TAILSCALE_AUTH_KEY_FILE must be an absolute path"
    run_as_root test -r "$AUTH_KEY_FILE" ||
        die "cannot read Tailscale auth-key file: $AUTH_KEY_FILE"
    up_args+=("--auth-key=file:$AUTH_KEY_FILE")
elif [[ $TEST_MODE != 1 && ! -t 0 && ! -t 1 ]]; then
    die "this machine needs login; rerun interactively or provide TAILSCALE_AUTH_KEY_FILE"
else
    printf '%s\n' \
        'Tailscale needs to join your tailnet.' \
        'Open the login URL printed below on any device and approve this machine.'
fi

run_as_root "$TAILSCALE_BIN" "${up_args[@]}"
for _attempt in {1..20}; do
    connected_ip=$(tailscale_ipv4 || true)
    [[ -z $connected_ip ]] || break
    sleep 1
done
[[ -n $connected_ip ]] || die "Tailscale authentication completed without an active tailnet address"
printf 'Tailscale connected at %s; SimpleServe remote transport is available.\n' \
    "$connected_ip"
