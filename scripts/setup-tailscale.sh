#!/usr/bin/env bash
set -euo pipefail

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
FAMILY=${SCRIPTORIUM_TAILSCALE_FAMILY:-$("$ROOT/detect-platform.sh")}
HOST_OS=${SCRIPTORIUM_TAILSCALE_HOST_OS:-$(uname -s 2>/dev/null || true)}
TEST_MODE=${SCRIPTORIUM_TAILSCALE_TEST_MODE:-0}
FORCE_INSTALL=${SCRIPTORIUM_TAILSCALE_FORCE_INSTALL:-0}
SYSTEM_ROOT=${SCRIPTORIUM_TAILSCALE_SYSTEM_ROOT:-}
INIT_OVERRIDE=${SCRIPTORIUM_TAILSCALE_INIT:-}
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

root_path() {
    printf '%s%s\n' "$SYSTEM_ROOT" "$1"
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

download() {
    local url=$1 output=$2

    curl --fail --silent --show-error --location --output "$output" "$url"
    [[ -s $output ]] || die "downloaded an empty file from $url"
}

install_tailscale_debian() {
    local distro codename id id_like ubuntu_codename version_codename
    local base key_target list_target expected_line
    local -a repository_lines=()

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
               [[ " $id_like " == *" ubuntu " || " $id_like " == *" debian " ]]; then
                distro=ubuntu
                codename=$ubuntu_codename
            else
                die "the official Tailscale APT repository is unknown for ${id:-this distribution}"
            fi
            ;;
    esac
    [[ $codename =~ ^[a-z0-9][a-z0-9-]*$ ]] ||
        die "could not determine a safe Debian/Ubuntu release codename"

    base=https://pkgs.tailscale.com/stable/$distro
    download "$base/$codename.noarmor.gpg" \
        "$WORK_DIR/tailscale-archive-keyring.gpg"
    download "$base/$codename.tailscale-keyring.list" \
        "$WORK_DIR/tailscale.list"

    mapfile -t repository_lines < <(
        sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' \
            "$WORK_DIR/tailscale.list"
    )
    expected_line="deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] $base $codename main"
    ((${#repository_lines[@]} == 1)) && [[ ${repository_lines[0]} == "$expected_line" ]] ||
        die "the downloaded Tailscale APT repository definition was not recognized"

    key_target=$(root_path /usr/share/keyrings/tailscale-archive-keyring.gpg)
    list_target=$(root_path /etc/apt/sources.list.d/tailscale.list)
    run_as_root install -d -m 0755 \
        "$(root_path /usr/share/keyrings)" "$(root_path /etc/apt/sources.list.d)"
    install_root_file_if_changed \
        "$WORK_DIR/tailscale-archive-keyring.gpg" "$key_target" 644
    install_root_file_if_changed "$WORK_DIR/tailscale.list" "$list_target" 644
    run_as_root env DEBIAN_FRONTEND=noninteractive LC_ALL=C apt-get update
    run_as_root env DEBIAN_FRONTEND=noninteractive LC_ALL=C \
        apt-get install -y tailscale
}

render_expected_rpm_repository() {
    local distro=$1 release_path=$2 output=$3

    printf '%s\n' \
        '[tailscale-stable]' \
        'name=Tailscale stable' \
        "baseurl=https://pkgs.tailscale.com/stable/$distro/$release_path/\$basearch" \
        'enabled=1' \
        'type=rpm' \
        'repo_gpgcheck=1' \
        'gpgcheck=1' \
        "gpgkey=https://pkgs.tailscale.com/stable/$distro/$release_path/repo.gpg" \
        > "$output"
}

install_tailscale_fedora() {
    local url target

    url=https://pkgs.tailscale.com/stable/fedora/tailscale.repo
    download "$url" "$WORK_DIR/tailscale.repo"
    render_expected_rpm_repository fedora '' "$WORK_DIR/expected.repo"
    # The generic Fedora repository omits the empty path component.
    sed -i 's|fedora//|fedora/|g' "$WORK_DIR/expected.repo"
    cmp -s "$WORK_DIR/tailscale.repo" "$WORK_DIR/expected.repo" ||
        die "the downloaded Tailscale Fedora repository definition was not recognized"
    target=$(root_path /etc/yum.repos.d/tailscale.repo)
    run_as_root install -d -m 0755 "$(root_path /etc/yum.repos.d)"
    install_root_file_if_changed "$WORK_DIR/tailscale.repo" "$target" 644
    run_as_root env LC_ALL=C dnf install -y tailscale
}

install_tailscale_suse() {
    local distro_id release_path target url version_id

    distro_id=$(release_value ID)
    version_id=$(release_value VERSION_ID)
    case $distro_id in
        opensuse-tumbleweed | opensuse-slowroll) release_path=tumbleweed ;;
        opensuse-leap | sles)
            [[ $version_id =~ ^[0-9]+([.][0-9]+)?$ ]] ||
                die "could not determine a safe openSUSE/SLES release version"
            release_path=leap/$version_id
            ;;
        *) die "the official Tailscale repository is unknown for ${distro_id:-this SUSE release}" ;;
    esac
    url=https://pkgs.tailscale.com/stable/opensuse/$release_path/tailscale.repo
    download "$url" "$WORK_DIR/tailscale.repo"
    render_expected_rpm_repository opensuse "$release_path" "$WORK_DIR/expected.repo"
    cmp -s "$WORK_DIR/tailscale.repo" "$WORK_DIR/expected.repo" ||
        die "the downloaded Tailscale openSUSE repository definition was not recognized"
    target=$(root_path /etc/zypp/repos.d/tailscale.repo)
    run_as_root install -d -m 0755 "$(root_path /etc/zypp/repos.d)"
    install_root_file_if_changed "$WORK_DIR/tailscale.repo" "$target" 644
    run_as_root env LC_ALL=C zypper --non-interactive refresh
    run_as_root env LC_ALL=C zypper --non-interactive install tailscale
}

find_brew() {
    local candidate

    if command -v brew >/dev/null 2>&1; then
        command -v brew
        return
    fi
    for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew; do
        [[ -x $candidate ]] || continue
        printf '%s\n' "$candidate"
        return
    done
    return 1
}

install_tailscale() {
    local brew_bin

    case $FAMILY in
        debian) install_tailscale_debian ;;
        fedora) install_tailscale_fedora ;;
        arch)
            run_as_root env LC_ALL=C pacman -Syu --needed --noconfirm tailscale
            ;;
        alpine)
            run_as_root env LC_ALL=C apk add tailscale
            ;;
        void)
            run_as_root env LC_ALL=C xbps-install -Sy tailscale
            ;;
        suse) install_tailscale_suse ;;
        freebsd)
            run_as_root env LC_ALL=C pkg update
            run_as_root env LC_ALL=C pkg install -y tailscale
            ;;
        macos)
            brew_bin=$(find_brew || true)
            [[ -n $brew_bin ]] || die "Homebrew is required to install Tailscale on macOS"
            env LC_ALL=C "$brew_bin" install tailscale
            ;;
        *) die "automatic Tailscale installation does not support platform family: $FAMILY" ;;
    esac
    hash -r
}

find_tailscale() {
    local candidate

    if command -v tailscale >/dev/null 2>&1; then
        command -v tailscale
        return
    fi
    for candidate in \
        /usr/bin/tailscale /usr/local/bin/tailscale \
        /opt/homebrew/bin/tailscale /usr/local/sbin/tailscale \
        /Applications/Tailscale.app/Contents/MacOS/Tailscale; do
        [[ -x $candidate ]] || continue
        printf '%s\n' "$candidate"
        return
    done
    return 1
}

tailscale_cli() {
    TAILSCALE_BE_CLI=1 "$TAILSCALE_BIN" "$@"
}

tailscale_ipv4() {
    local address status

    status=$(tailscale_cli status --json 2>/dev/null || true)
    grep -Eq '"BackendState"[[:space:]]*:[[:space:]]*"Running"' <<<"$status" ||
        return 1
    address=$(tailscale_cli ip -4 2>/dev/null | sed -n '1p')
    case $address in
        100.6[4-9].* | 100.[7-9][0-9].* | 100.1[01][0-9].* | 100.12[0-7].*)
            printf '%s\n' "$address"
            ;;
        *) return 1 ;;
    esac
}

detect_init_system() {
    if [[ -n $INIT_OVERRIDE ]]; then
        printf '%s\n' "$INIT_OVERRIDE"
        return
    fi
    case $HOST_OS in
        Darwin)
            if [[ $TAILSCALE_BIN == /Applications/Tailscale.app/* ]]; then
                printf '%s\n' macapp
            else
                printf '%s\n' macbrew
            fi
            ;;
        FreeBSD) printf '%s\n' freebsd ;;
        Linux)
            if command -v systemctl >/dev/null 2>&1 &&
               [[ -d $(root_path /run/systemd/system) ]]; then
                printf '%s\n' systemd
            elif command -v rc-service >/dev/null 2>&1 &&
                 command -v rc-update >/dev/null 2>&1; then
                printf '%s\n' openrc
            elif command -v sv >/dev/null 2>&1 &&
                 [[ -d $(root_path /etc/sv) ]]; then
                printf '%s\n' runit
            else
                die "no supported service manager was found (systemd, OpenRC, or runit)"
            fi
            ;;
        *) die "no Tailscale service integration is available for $HOST_OS" ;;
    esac
}

ensure_runit_link() {
    local link source current

    source=/etc/sv/tailscaled
    link=$(root_path /var/service/tailscaled)
    [[ -d $(root_path "$source") ]] ||
        die "the Void Tailscale package did not install $source"
    run_as_root install -d -m 0755 "$(root_path /var/service)"
    if run_as_root test -L "$link"; then
        current=$(run_as_root readlink "$link")
        [[ $current == "$source" ]] ||
            die "$link points to $current instead of $source"
    elif run_as_root test -e "$link"; then
        die "$link exists and is not the managed Tailscale service link"
    else
        run_as_root ln -s "$source" "$link"
    fi
}

ensure_tailscale_service() {
    local brew_bin enabled

    case $INIT_SYSTEM in
        systemd)
            if ! run_as_root systemctl is-enabled --quiet tailscaled.service 2>/dev/null; then
                run_as_root systemctl enable tailscaled.service
            fi
            if ! run_as_root systemctl is-active --quiet tailscaled.service; then
                run_as_root systemctl start tailscaled.service
            fi
            run_as_root systemctl is-active --quiet tailscaled.service ||
                die "tailscaled.service did not become active"
            ;;
        openrc)
            if ! rc-update show default 2>/dev/null |
                grep -Eq '(^|[[:space:]])tailscale([[:space:]]|$)'; then
                run_as_root rc-update add tailscale default >/dev/null
            fi
            if ! run_as_root rc-service tailscale status >/dev/null 2>&1; then
                run_as_root rc-service tailscale start
            fi
            run_as_root rc-service tailscale status >/dev/null 2>&1 ||
                die "the Tailscale OpenRC service did not become active"
            ;;
        runit)
            ensure_runit_link
            if ! run_as_root sv status tailscaled >/dev/null 2>&1; then
                run_as_root sv up tailscaled
            fi
            run_as_root sv status tailscaled >/dev/null 2>&1 ||
                die "the Tailscale runit service did not become active"
            ;;
        freebsd)
            enabled=$(run_as_root sysrc -n tailscaled_enable 2>/dev/null || true)
            [[ $enabled == YES ]] || run_as_root sysrc -q tailscaled_enable=YES
            if ! run_as_root service tailscaled onestatus >/dev/null 2>&1; then
                run_as_root service tailscaled start
            fi
            run_as_root service tailscaled onestatus >/dev/null 2>&1 ||
                die "the Tailscale FreeBSD service did not become active"
            ;;
        macbrew)
            brew_bin=$(find_brew || true)
            [[ -n $brew_bin ]] || die "Homebrew disappeared after installing Tailscale"
            if ! pgrep -x tailscaled >/dev/null 2>&1; then
                if [[ $TEST_MODE == 1 || $(id -u) -eq 0 ]]; then
                    env HOME="$HOME" "$brew_bin" services start tailscale
                elif command -v sudo >/dev/null 2>&1; then
                    sudo --preserve-env=HOME "$brew_bin" services start tailscale
                else
                    die "sudo is required to start the Homebrew Tailscale daemon"
                fi
            fi
            ;;
        macapp)
            open -a Tailscale
            ;;
        *) die "unsupported Tailscale service manager: $INIT_SYSTEM" ;;
    esac
}

run_tailscale_up() {
    if [[ $INIT_SYSTEM == macapp ]]; then
        tailscale_cli "$@"
    else
        run_as_root env TAILSCALE_BE_CLI=1 "$TAILSCALE_BIN" "$@"
    fi
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
case $INIT_OVERRIDE in
    '' | systemd | openrc | runit | freebsd | macbrew | macapp) ;;
    *) die "unsupported SCRIPTORIUM_TAILSCALE_INIT value: $INIT_OVERRIDE" ;;
esac

TAILSCALE_BIN=$(find_tailscale || true)
if [[ $FORCE_INSTALL == 1 || -z $TAILSCALE_BIN ]]; then
    printf 'Installing Tailscale for %s from its native trusted package source...\n' "$FAMILY"
    install_tailscale
    TAILSCALE_BIN=$(find_tailscale || true)
fi
[[ -n $TAILSCALE_BIN ]] || die "the tailscale command is unavailable after installation"

# This is the strict no-churn path: do not touch the package database, service,
# identity, or preferences when an already-running node is connected.
connected_ip=$(tailscale_ipv4 || true)
if [[ -n $connected_ip ]]; then
    printf 'Tailscale already connected at %s; preserving its identity and preferences.\n' \
        "$connected_ip"
    exit 0
fi

INIT_SYSTEM=$(detect_init_system)
ensure_tailscale_service

# A previously enrolled but stopped node becomes connected once its daemon starts.
connected_ip=$(tailscale_ipv4 || true)
if [[ -n $connected_ip ]]; then
    printf 'Tailscale reconnected at %s; preserving its identity and preferences.\n' \
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

run_tailscale_up "${up_args[@]}"
for _attempt in {1..20}; do
    connected_ip=$(tailscale_ipv4 || true)
    [[ -z $connected_ip ]] || break
    sleep 1
done
[[ -n $connected_ip ]] || die "Tailscale authentication completed without an active tailnet address"
printf 'Tailscale connected at %s; SimpleServe remote transport is available.\n' \
    "$connected_ip"
