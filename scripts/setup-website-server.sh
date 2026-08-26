#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
DEFAULT_SCRIPTORIUM_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd -P)
SCRIPTORIUM_ROOT=${SCRIPTORIUM_ROOT:-$DEFAULT_SCRIPTORIUM_ROOT}
SERVER_ROOT=${SCRIPTORIUM_SERVER_ROOT:-$SCRIPTORIUM_ROOT/scripts/server}
SITE_ROOT=${WEBSITE_DIR:-$HOME/website}
SITE_USER=$(id -un)
SITE_GROUP=$(id -gn)
SITE_UID=$(id -u)
SITE_GID=$(id -g)
SITE_HOME=$HOME
EXPECTED_ROOT=$SITE_HOME/website
CONFIG_DIR=$SITE_HOME/.config/keelanwatlington
STATE_DIR=$SITE_HOME/.local/state/keelanwatlington-store
ENV_FILE=$CONFIG_DIR/store.env
ORDERS_DB=$STATE_DIR/orders.sqlite3
STORE_CODE_MARKER=$STATE_DIR/store-code.sha256
SITE_ADDRESS=:8080
PUBLIC_ORIGIN=${WEBSITE_PUBLIC_ORIGIN:-https://keelanwatlington.com}
CLOUDFLARE_TOKEN_TARGET=/etc/cloudflared/keelanwatlington.token
CLOUDFLARE_API_TOKEN_TARGET=/etc/cloudflared/keelanwatlington-api.token
CLOUDFLARE_CONFIG_TARGET=/etc/cloudflared/config.yml
CLOUDFLARE_CREDENTIALS_TARGET=/etc/cloudflared/keelanwatlington-credentials.json
CLOUDFLARE_TUNNEL_ID=beb29759-dac7-43c9-a66d-36153e9b90fd
CLOUDFLARE_APEX_HOSTNAME=keelanwatlington.com
CLOUDFLARE_WWW_HOSTNAME=www.keelanwatlington.com
CLOUDFLARE_KEY_URL=https://pkg.cloudflare.com/cloudflare-main.gpg
CLOUDFLARE_KEY_TARGET=/usr/share/keyrings/cloudflare-main.gpg
CLOUDFLARE_APT_SOURCE=/etc/apt/sources.list.d/cloudflared.list
PORTABLE_LAUNCHER_DIR=/usr/local/libexec/keelanwatlington
INSTALL_PACKAGES=1
ENABLE_BLOG_TIMER=1
ENABLE_CLOUDFLARE=1
CHECK_PUBLIC=1
NON_INTERACTIVE=0
VERIFY_ONLY=0
STORE_ENV_IMPORT=${WEBSITE_STORE_ENV_BACKUP:-}
ORDERS_DB_IMPORT=${WEBSITE_ORDERS_DB_BACKUP:-}
CLOUDFLARE_TOKEN_INPUT=${WEBSITE_CLOUDFLARE_TOKEN_FILE:-}
CLOUDFLARE_API_TOKEN_INPUT=${WEBSITE_CLOUDFLARE_API_TOKEN_FILE:-}
CLOUDFLARE_CONFIG_IMPORT=${WEBSITE_CLOUDFLARE_CONFIG_BACKUP:-}
CLOUDFLARE_CREDENTIALS_IMPORT=${WEBSITE_CLOUDFLARE_CREDENTIALS_BACKUP:-}
CLOUDFLARE_TOKEN_ENV=${CLOUDFLARED_TUNNEL_TOKEN:-}
CLOUDFLARE_API_TOKEN_ENV=${CLOUDFLARE_API_TOKEN:-}
STATE_BACKUP_DIR=${WEBSITE_STATE_BACKUP:-}
unset CLOUDFLARED_TUNNEL_TOKEN CLOUDFLARE_API_TOKEN

# shellcheck source=server/platform.sh
. "$SERVER_ROOT/platform.sh"

usage() {
  cat <<'EOF'
Usage: setup-server [OPTIONS]

Configure Keelan's Networking Trident website prong from Scriptorium. Supported
families are Debian/Ubuntu, Fedora, Arch, Alpine, Void, openSUSE Tumbleweed,
FreeBSD, and macOS. Run as the login user; sudo is used only for packages and
system configuration.

Options:
  --skip-packages                 Require dependencies instead of installing them
  --no-blog-timer                 Disable automatic Substack checks
  --no-cloudflare                 Configure only the local Caddy origin
  --no-public-check               Skip the final HTTPS check through Cloudflare
  --non-interactive               Fail rather than prompt for missing secrets
  --state-backup DIRECTORY        Restore Stripe, orders, and tunnel snapshot
  --store-env FILE                Restore an existing store.env before setup
  --orders-db FILE                Restore an existing orders.sqlite3 database
  --cloudflare-token-file FILE    Read a Cloudflare tunnel token from FILE
  --cloudflare-api-token-file FILE
                                  Read a Tunnel/DNS management API token from FILE
  --cloudflare-config FILE        Restore a locally managed tunnel config
  --cloudflare-credentials FILE   Restore that tunnel's credentials JSON
  --site-address ADDRESS          Local Caddy listener (default: :8080)
  --verify-only                   Change nothing; verify the installed stack
  -h, --help                      Show this help

For unattended setup, STRIPE_WEBHOOK_SECRETS, CLOUDFLARED_TUNNEL_TOKEN, and
CLOUDFLARE_API_TOKEN may be supplied in the environment. The API token needs
Account / Cloudflare Tunnel / Edit plus Zone / Zone / Read and Zone / DNS /
Edit for keelanwatlington.com. Existing protected configuration is reused.

Before wiping an old server, run:
  ~/scriptorium/scripts/backup-server-state.sh /path/to/private-backup
Then restore with:
  setup-server --state-backup /path/to/private-backup
Without that bundle, setup can ask for the Stripe webhook secret, a new tunnel
connector token, and a Tunnel/DNS management API token, but it cannot
reconstruct old paid-order history.
EOF
}

die() {
  printf 'setup-server: %s\n' "$*" >&2
  exit 1
}

require_argument() {
  local option=$1
  shift
  (($#)) || die "$option requires a value"
}

while (($#)); do
  case "$1" in
    --skip-packages) INSTALL_PACKAGES=0 ;;
    --no-blog-timer) ENABLE_BLOG_TIMER=0 ;;
    --no-cloudflare) ENABLE_CLOUDFLARE=0; CHECK_PUBLIC=0 ;;
    --no-public-check) CHECK_PUBLIC=0 ;;
    --non-interactive) NON_INTERACTIVE=1 ;;
    --verify-only) VERIFY_ONLY=1 ;;
    --state-backup)
      shift
      require_argument --state-backup "$@"
      STATE_BACKUP_DIR=$1
      ;;
    --store-env)
      shift
      require_argument --store-env "$@"
      STORE_ENV_IMPORT=$1
      ;;
    --orders-db)
      shift
      require_argument --orders-db "$@"
      ORDERS_DB_IMPORT=$1
      ;;
    --cloudflare-token-file)
      shift
      require_argument --cloudflare-token-file "$@"
      CLOUDFLARE_TOKEN_INPUT=$1
      ;;
    --cloudflare-api-token-file)
      shift
      require_argument --cloudflare-api-token-file "$@"
      CLOUDFLARE_API_TOKEN_INPUT=$1
      ;;
    --cloudflare-config)
      shift
      require_argument --cloudflare-config "$@"
      CLOUDFLARE_CONFIG_IMPORT=$1
      ;;
    --cloudflare-credentials)
      shift
      require_argument --cloudflare-credentials "$@"
      CLOUDFLARE_CREDENTIALS_IMPORT=$1
      ;;
    --site-address)
      shift
      require_argument --site-address "$@"
      SITE_ADDRESS=$1
      ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done

[[ $EUID -ne 0 ]] || die "run this as the login user, not with sudo"
[[ $SCRIPTORIUM_ROOT == /* ]] || die "SCRIPTORIUM_ROOT must be an absolute path"
[[ $SERVER_ROOT == /* ]] || die "SCRIPTORIUM_SERVER_ROOT must be an absolute path"
[[ $SITE_ROOT == "$EXPECTED_ROOT" ]] || die "checkout must be $EXPECTED_ROOT (found $SITE_ROOT)"
[[ -d $SITE_ROOT/.git ]] || die "$SITE_ROOT is not a Git checkout"
for provision_asset in platform.sh configure_store.py render_server_config.py \
                       configure_cloudflare_tunnel.py check_server.sh \
                       verify_site.py Caddyfile.production; do
  [[ -f $SERVER_ROOT/$provision_asset ]] ||
    die "Scriptorium server asset is missing: $SERVER_ROOT/$provision_asset"
done
for payload_file in index.html tools/store_fulfillment.py tools/run_store.py \
                    tools/sync_blog.sh; do
  [[ -f $SITE_ROOT/$payload_file ]] ||
    die "website payload is missing: $SITE_ROOT/$payload_file"
done
[[ $SITE_ADDRESS != *[[:space:]]* ]] || die "site address cannot contain whitespace"
[[ $SITE_ADDRESS == :* ]] || die "site address must be a local listener such as :8080"
[[ $PUBLIC_ORIGIN == https://* ]] || die "WEBSITE_PUBLIC_ORIGIN must use https"
PUBLIC_ORIGIN=${PUBLIC_ORIGIN%/}

PLATFORM_FAMILY=$(website_detect_family)
SERVICE_MANAGER=$(website_detect_service_manager)
case $PLATFORM_FAMILY in
  debian|fedora|arch|alpine|void|suse|freebsd|macos) ;;
  *) die "unsupported platform; the Trident supports Debian, Fedora, Arch, Alpine, Void, openSUSE, FreeBSD, and macOS" ;;
esac
case $SERVICE_MANAGER in
  systemd|openrc|runit|freebsd|launchd) ;;
  *) die "no supported service manager was found (systemd, OpenRC, runit, FreeBSD rc.d, or launchd)" ;;
esac

resolve_state_backup() {
  [[ -n $STATE_BACKUP_DIR ]] || return 0
  [[ -d $STATE_BACKUP_DIR ]] || die "state backup directory is missing: $STATE_BACKUP_DIR"
  STORE_ENV_IMPORT=$STATE_BACKUP_DIR/store.env
  [[ ! -f $STATE_BACKUP_DIR/orders.sqlite3 ]] ||
    ORDERS_DB_IMPORT=$STATE_BACKUP_DIR/orders.sqlite3
  if [[ -f $STATE_BACKUP_DIR/cloudflared/config.yml ||
        -f $STATE_BACKUP_DIR/cloudflared/credentials.json ]]; then
    CLOUDFLARE_CONFIG_IMPORT=$STATE_BACKUP_DIR/cloudflared/config.yml
    CLOUDFLARE_CREDENTIALS_IMPORT=$STATE_BACKUP_DIR/cloudflared/credentials.json
  elif [[ -f $STATE_BACKUP_DIR/cloudflared/token ]]; then
    CLOUDFLARE_TOKEN_INPUT=$STATE_BACKUP_DIR/cloudflared/token
  fi
  [[ ! -f $STATE_BACKUP_DIR/cloudflared/api-token ]] ||
    CLOUDFLARE_API_TOKEN_INPUT=$STATE_BACKUP_DIR/cloudflared/api-token
}

resolve_state_backup

check_public_site() {
  local attempt health home_status www_status

  for attempt in {1..12}; do
    home_status=$(curl --silent --show-error --max-time 10 --output /dev/null \
      --write-out '%{http_code}' "$PUBLIC_ORIGIN/" 2>/dev/null || true)
    www_status=$(curl --silent --show-error --max-time 10 --output /dev/null \
      --write-out '%{http_code}' "https://www.keelanwatlington.com/" 2>/dev/null || true)
    health=$(curl --silent --show-error --max-time 10 \
      "$PUBLIC_ORIGIN/_store/health" 2>/dev/null || true)
    if [[ $home_status == 200 && $www_status == 200 && $health == *'"status":"ok"'* ]]; then
      printf 'public site verified: %s and www are live through Cloudflare\n' "$PUBLIC_ORIGIN"
      return 0
    fi
    ((attempt == 12)) || sleep 2
  done
  die "public site check failed; confirm both Cloudflare hostnames route to http://localhost${SITE_ADDRESS}"
}

verify_installed_stack() {
  local check_blog=0 check_cloudflared=0

  ((ENABLE_BLOG_TIMER)) && check_blog=1
  ((ENABLE_CLOUDFLARE)) && check_cloudflared=1
  CHECK_BLOG_TIMER=$check_blog \
    CHECK_CLOUDFLARED=$check_cloudflared \
    CADDY_CHECK_ORIGIN="http://127.0.0.1$SITE_ADDRESS" \
    WEBSITE_DIR=$SITE_ROOT \
    WEBSITE_PLATFORM_FAMILY=$PLATFORM_FAMILY \
    WEBSITE_SERVICE_MANAGER=$SERVICE_MANAGER \
    "$SERVER_ROOT/check_server.sh"
  if ((CHECK_PUBLIC)); then
    check_public_site
  fi
}

if ((VERIFY_ONLY)); then
  verify_installed_stack
  exit 0
fi

if [[ -z $STATE_BACKUP_DIR && -z $STORE_ENV_IMPORT && -z $ORDERS_DB_IMPORT ]] &&
   { [[ ! -f $ENV_FILE ]] || [[ ! -f $ORDERS_DB ]]; }; then
  cat >&2 <<'EOF'

Fresh website state detected. If this replaces an old server that still
exists, stop now and run there:
  ~/scriptorium/scripts/backup-server-state.sh /path/to/private-backup
Then rerun here with:
  setup-server --state-backup /path/to/private-backup
Without that bundle, setup can accept the Stripe webhook secret, a new tunnel
connector token, and a Tunnel/DNS management API token, but old paid-order
history cannot be reconstructed.

EOF
fi

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/keelanwatlington-setup.XXXXXX")
cleanup() {
  rm -rf -- "$WORK_DIR"
}
trap cleanup EXIT INT TERM

CADDY_CHANGED=0
STORE_CHANGED=0
BLOG_CHANGED=0
CLOUDFLARE_CHANGED=0
SYSTEMD_CHANGED=0
ROOT_GROUP=$(id -gn 0 2>/dev/null || printf '%s\n' root)
ROOT_GID=$(id -g 0 2>/dev/null || printf '%s\n' 0)

stat_mode() {
  stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null || true
}

stat_uid() {
  stat -c %u "$1" 2>/dev/null || stat -f %u "$1" 2>/dev/null || true
}

stat_gid() {
  stat -c %g "$1" 2>/dev/null || stat -f %g "$1" 2>/dev/null || true
}

root_stat_mode() {
  sudo stat -c %a "$1" 2>/dev/null || sudo stat -f %Lp "$1" 2>/dev/null || true
}

root_stat_uid() {
  sudo stat -c %u "$1" 2>/dev/null || sudo stat -f %u "$1" 2>/dev/null || true
}

root_stat_gid() {
  sudo stat -c %g "$1" 2>/dev/null || sudo stat -f %g "$1" 2>/dev/null || true
}

ensure_root_directory() {
  local directory=$1 mode=${2:-755}

  if sudo test -d "$directory" && [[ $(root_stat_mode "$directory") == "$mode" ]] &&
     [[ $(root_stat_uid "$directory") == 0 ]]; then
    return 0
  fi
  sudo install -d -m "0$mode" -o root -g "$ROOT_GROUP" "$directory"
}

install_root_file_if_changed() {
  local source=$1 target=$2 mode=$3 changed_variable=$4
  local secondary_changed_variable=${5:-}

  if sudo test -f "$target" && [[ $(root_stat_mode "$target") == "$mode" ]] &&
     [[ $(root_stat_uid "$target") == 0 ]] && [[ $(root_stat_gid "$target") == "$ROOT_GID" ]] &&
     sudo cmp -s "$source" "$target"; then
    return 0
  fi
  ensure_root_directory "$(dirname -- "$target")" 755
  sudo install -m "0$mode" -o root -g "$ROOT_GROUP" "$source" "$target"
  printf -v "$changed_variable" '%s' 1
  [[ -z $secondary_changed_variable ]] || printf -v "$secondary_changed_variable" '%s' 1
}

install_user_file_if_changed() {
  local source=$1 target=$2 mode=$3 changed_variable=$4

  if [[ -f $target && $(stat_mode "$target") == "$mode" &&
        $(stat_uid "$target") == "$SITE_UID" && $(stat_gid "$target") == "$SITE_GID" ]] &&
     cmp -s "$source" "$target"; then
    return 0
  fi
  mkdir -p "$(dirname -- "$target")"
  install -m "0$mode" "$source" "$target"
  printf -v "$changed_variable" '%s' 1
}

ensure_private_directory() {
  local directory=$1

  [[ -d $directory ]] || mkdir -p "$directory"
  [[ $(stat_mode "$directory") == 700 ]] || chmod 0700 "$directory"
}

add_package() {
  local candidate=$1 existing

  for existing in "${MISSING_PACKAGES[@]:-}"; do
    [[ $existing != "$candidate" ]] || return 0
  done
  MISSING_PACKAGES+=("$candidate")
}

package_for() {
  local command_name=$1

  case "$PLATFORM_FAMILY:$command_name" in
    arch:python3) printf '%s\n' python ;;
    macos:python3) printf '%s\n' python ;;
    freebsd:caddy) printf '%s\n' caddy2 ;;
    *:setfacl|*:getfacl) printf '%s\n' acl ;;
    *) printf '%s\n' "$command_name" ;;
  esac
}

run_package_install() {
  ((${#MISSING_PACKAGES[@]})) || return 0
  ((INSTALL_PACKAGES)) || die "missing packages or commands: ${MISSING_PACKAGES[*]}"

  case $PLATFORM_FAMILY in
    debian)
      sudo env DEBIAN_FRONTEND=noninteractive LC_ALL=C apt-get update
      sudo env DEBIAN_FRONTEND=noninteractive LC_ALL=C apt-get install -y "${MISSING_PACKAGES[@]}"
      ;;
    fedora) sudo env LC_ALL=C dnf install -y "${MISSING_PACKAGES[@]}" ;;
    arch) sudo env LC_ALL=C pacman -Syu --needed --noconfirm "${MISSING_PACKAGES[@]}" ;;
    alpine) sudo env LC_ALL=C apk add "${MISSING_PACKAGES[@]}" ;;
    void) sudo env LC_ALL=C xbps-install -Sy "${MISSING_PACKAGES[@]}" ;;
    suse)
      sudo env LC_ALL=C zypper --non-interactive refresh
      sudo env LC_ALL=C zypper --non-interactive install "${MISSING_PACKAGES[@]}"
      ;;
    freebsd)
      sudo env LC_ALL=C pkg update
      sudo env LC_ALL=C pkg install -y "${MISSING_PACKAGES[@]}"
      ;;
    macos)
      command -v brew >/dev/null 2>&1 || die "Homebrew is required on macOS; install it through Scriptorium first"
      env LC_ALL=C brew install "${MISSING_PACKAGES[@]}"
      ;;
  esac
  hash -r
}

install_core_packages() {
  local command_name
  MISSING_PACKAGES=()
  for command_name in caddy python3 curl git; do
    command -v "$command_name" >/dev/null 2>&1 || add_package "$(package_for "$command_name")"
  done
  if [[ $SERVICE_MANAGER == systemd ]]; then
    command -v setfacl >/dev/null 2>&1 || add_package "$(package_for setfacl)"
    command -v getfacl >/dev/null 2>&1 || add_package "$(package_for getfacl)"
  fi
  run_package_install

  for command_name in caddy python3 curl git; do
    command -v "$command_name" >/dev/null 2>&1 || die "$command_name is unavailable after package installation"
  done
  if [[ $SERVICE_MANAGER == systemd ]]; then
    command -v setfacl >/dev/null 2>&1 && command -v getfacl >/dev/null 2>&1 ||
      die "ACL tools are unavailable after package installation"
  fi
}

install_cloudflared_debian() {
  local source_file=$WORK_DIR/cloudflared.list

  curl --fail --silent --show-error --location \
    --output "$WORK_DIR/cloudflare-main.gpg" "$CLOUDFLARE_KEY_URL"
  [[ -s $WORK_DIR/cloudflare-main.gpg ]] || die "Cloudflare signing key download was empty"
  printf '%s\n' \
    "deb [signed-by=$CLOUDFLARE_KEY_TARGET] https://pkg.cloudflare.com/cloudflared any main" \
    > "$source_file"
  ensure_root_directory /usr/share/keyrings 755
  ensure_root_directory /etc/apt/sources.list.d 755
  local repository_changed=0
  install_root_file_if_changed "$WORK_DIR/cloudflare-main.gpg" \
    "$CLOUDFLARE_KEY_TARGET" 644 repository_changed
  install_root_file_if_changed "$source_file" "$CLOUDFLARE_APT_SOURCE" \
    644 repository_changed
  sudo env DEBIAN_FRONTEND=noninteractive LC_ALL=C apt-get update
  sudo env DEBIAN_FRONTEND=noninteractive LC_ALL=C apt-get install -y cloudflared
}

install_cloudflared_binary() {
  local architecture asset api_json url expected_digest actual_digest

  case $(uname -m) in
    x86_64|amd64) architecture=amd64 ;;
    aarch64|arm64) architecture=arm64 ;;
    armv7l|armv6l) architecture=arm ;;
    i386|i686) architecture=386 ;;
    *) die "no official cloudflared Linux binary is published for $(uname -m)" ;;
  esac
  asset=cloudflared-linux-$architecture
  api_json=$WORK_DIR/cloudflared-release.json
  curl --fail --silent --show-error --location \
    --output "$api_json" \
    https://api.github.com/repos/cloudflare/cloudflared/releases/latest
  IFS=$'\t' read -r url expected_digest < <(
    "$PYTHON_BIN" - "$api_json" "$asset" <<'PY'
import json
import sys

release = json.load(open(sys.argv[1], encoding="utf-8"))
matches = [asset for asset in release.get("assets", []) if asset.get("name") == sys.argv[2]]
if len(matches) != 1:
    raise SystemExit(f"expected one official {sys.argv[2]} release asset, found {len(matches)}")
asset = matches[0]
digest = asset.get("digest", "")
url = asset.get("browser_download_url", "")
if not digest.startswith("sha256:") or len(digest) != 71:
    raise SystemExit("official cloudflared release asset has no usable SHA-256 digest")
if not url.startswith("https://github.com/cloudflare/cloudflared/releases/download/"):
    raise SystemExit("official cloudflared release asset URL was not recognized")
print(url, digest.split(":", 1)[1], sep="\t")
PY
  )
  [[ -n $url && -n $expected_digest ]] || die "could not resolve the verified cloudflared release"
  curl --fail --silent --show-error --location \
    --output "$WORK_DIR/cloudflared" "$url"
  actual_digest=$("$PYTHON_BIN" - "$WORK_DIR/cloudflared" <<'PY'
import hashlib
import sys

digest = hashlib.sha256()
with open(sys.argv[1], "rb") as source:
    for chunk in iter(lambda: source.read(1024 * 1024), b""):
        digest.update(chunk)
print(digest.hexdigest())
PY
  )
  [[ $actual_digest == "$expected_digest" ]] || die "cloudflared release digest verification failed"
  sudo install -m 0755 -o root -g "$ROOT_GROUP" "$WORK_DIR/cloudflared" \
    /usr/local/bin/cloudflared
}

install_cloudflared_package() {
  command -v cloudflared >/dev/null 2>&1 && return 0
  ((INSTALL_PACKAGES)) || die "cloudflared is missing and --skip-packages was requested"

  case $PLATFORM_FAMILY in
    debian) install_cloudflared_debian ;;
    arch) sudo env LC_ALL=C pacman -Syu --needed --noconfirm cloudflared ;;
    void) sudo env LC_ALL=C xbps-install -Sy cloudflared ;;
    freebsd) sudo env LC_ALL=C pkg install -y cloudflared ;;
    macos)
      command -v brew >/dev/null 2>&1 || die "Homebrew is required to install cloudflared on macOS"
      env LC_ALL=C brew install cloudflared
      ;;
    fedora|alpine|suse) install_cloudflared_binary ;;
  esac
  hash -r
  command -v cloudflared >/dev/null 2>&1 || die "cloudflared is unavailable after installation"
}

portable_service_name() {
  case $1 in
    caddy) printf '%s\n' keelanwatlington-caddy ;;
    store) printf '%s\n' keelanwatlington-store ;;
    blog) printf '%s\n' keelanwatlington-blog-sync ;;
    cloudflared) printf '%s\n' keelanwatlington-cloudflared ;;
  esac
}

freebsd_service_name() {
  case $1 in
    caddy) printf '%s\n' keelanwatlington_caddy ;;
    store) printf '%s\n' keelanwatlington_store ;;
    blog) printf '%s\n' keelanwatlington_blog_sync ;;
    cloudflared) printf '%s\n' keelanwatlington_cloudflared ;;
  esac
}

launchd_service_label() {
  case $1 in
    caddy) printf '%s\n' com.keelanwatlington.caddy ;;
    store) printf '%s\n' com.keelanwatlington.store ;;
    blog) printf '%s\n' com.keelanwatlington.blog-sync ;;
    cloudflared) printf '%s\n' com.keelanwatlington.cloudflared ;;
  esac
}

systemd_service_name() {
  case $1 in
    caddy) printf '%s\n' caddy.service ;;
    store) printf '%s\n' keelanwatlington-store.service ;;
    blog) printf '%s\n' keelanwatlington-blog-sync.timer ;;
    cloudflared) printf '%s\n' cloudflared.service ;;
  esac
}

service_is_active() {
  local logical=$1 name label

  case $SERVICE_MANAGER in
    systemd)
      name=$(systemd_service_name "$logical")
      sudo systemctl is-active --quiet "$name" 2>/dev/null
      ;;
    openrc)
      name=$(portable_service_name "$logical")
      sudo rc-service "$name" status >/dev/null 2>&1
      ;;
    runit)
      name=$(portable_service_name "$logical")
      sudo sv status "$name" >/dev/null 2>&1
      ;;
    freebsd)
      name=$(freebsd_service_name "$logical")
      sudo service "$name" onestatus >/dev/null 2>&1
      ;;
    launchd)
      label=$(launchd_service_label "$logical")
      sudo launchctl print "system/$label" >/dev/null 2>&1
      ;;
  esac
}

ensure_service_enabled() {
  local logical=$1 name link source current enabled

  case $SERVICE_MANAGER in
    systemd)
      name=$(systemd_service_name "$logical")
      sudo systemctl is-enabled --quiet "$name" 2>/dev/null || sudo systemctl enable "$name"
      ;;
    openrc)
      name=$(portable_service_name "$logical")
      sudo rc-update show default 2>/dev/null |
        grep -Eq "(^|[[:space:]])$name([[:space:]]|$)" ||
        sudo rc-update add "$name" default >/dev/null
      ;;
    runit)
      name=$(portable_service_name "$logical")
      source=/etc/sv/$name
      link=/var/service/$name
      sudo test -d "$source" || die "runit definition is missing: $source"
      ensure_root_directory /var/service 755
      if sudo test -L "$link"; then
        current=$(sudo readlink "$link")
        [[ $current == "$source" ]] || die "$link points to $current instead of $source"
      elif sudo test -e "$link"; then
        die "$link exists and is not the managed service link"
      else
        sudo ln -s "$source" "$link"
      fi
      ;;
    freebsd)
      name=$(freebsd_service_name "$logical")
      enabled=$(sudo sysrc -n "${name}_enable" 2>/dev/null || true)
      [[ $enabled == YES ]] || sudo sysrc -q "${name}_enable=YES"
      ;;
    launchd) ;;
  esac
}

start_or_restart_service() {
  local logical=$1 changed=$2 name label plist

  case $SERVICE_MANAGER in
    systemd)
      name=$(systemd_service_name "$logical")
      if service_is_active "$logical"; then
        ((changed == 0)) || sudo systemctl restart "$name"
      else
        sudo systemctl start "$name"
      fi
      ;;
    openrc)
      name=$(portable_service_name "$logical")
      if service_is_active "$logical"; then
        ((changed == 0)) || sudo rc-service "$name" restart
      else
        sudo rc-service "$name" start
      fi
      ;;
    runit)
      name=$(portable_service_name "$logical")
      if service_is_active "$logical"; then
        ((changed == 0)) || sudo sv restart "$name"
      else
        sudo sv up "$name"
      fi
      ;;
    freebsd)
      name=$(freebsd_service_name "$logical")
      if service_is_active "$logical"; then
        ((changed == 0)) || sudo service "$name" restart
      else
        sudo service "$name" start
      fi
      ;;
    launchd)
      label=$(launchd_service_label "$logical")
      plist=/Library/LaunchDaemons/$label.plist
      if service_is_active "$logical"; then
        if ((changed)); then
          sudo launchctl bootout "system/$label"
          sudo launchctl enable "system/$label"
          sudo launchctl bootstrap system "$plist"
          sudo launchctl kickstart -k "system/$label"
        fi
      else
        sudo launchctl enable "system/$label"
        sudo launchctl bootstrap system "$plist"
        sudo launchctl kickstart -k "system/$label"
      fi
      ;;
  esac
}

stop_service() {
  local logical=$1 name label

  service_is_active "$logical" || return 0
  case $SERVICE_MANAGER in
    systemd) name=$(systemd_service_name "$logical"); sudo systemctl stop "$name" ;;
    openrc) name=$(portable_service_name "$logical"); sudo rc-service "$name" stop ;;
    runit) name=$(portable_service_name "$logical"); sudo sv down "$name" ;;
    freebsd) name=$(freebsd_service_name "$logical"); sudo service "$name" stop ;;
    launchd) label=$(launchd_service_label "$logical"); sudo launchctl bootout "system/$label" ;;
  esac
}

disable_service() {
  local logical=$1 name label link expected enabled

  stop_service "$logical"
  case $SERVICE_MANAGER in
    systemd)
      name=$(systemd_service_name "$logical")
      sudo systemctl is-enabled --quiet "$name" 2>/dev/null && sudo systemctl disable "$name" || true
      ;;
    openrc)
      name=$(portable_service_name "$logical")
      sudo rc-update show default 2>/dev/null |
        grep -Eq "(^|[[:space:]])$name([[:space:]]|$)" &&
        sudo rc-update del "$name" default >/dev/null || true
      ;;
    runit)
      name=$(portable_service_name "$logical")
      link=/var/service/$name
      expected=/etc/sv/$name
      if sudo test -L "$link" && [[ $(sudo readlink "$link") == "$expected" ]]; then
        sudo unlink "$link"
      fi
      ;;
    freebsd)
      name=$(freebsd_service_name "$logical")
      enabled=$(sudo sysrc -n "${name}_enable" 2>/dev/null || true)
      [[ $enabled != YES ]] || sudo sysrc -q "${name}_enable=NO"
      ;;
    launchd)
      label=$(launchd_service_label "$logical")
      if ! sudo launchctl print-disabled system 2>/dev/null |
        grep -Fq "\"$label\" => true"; then
        sudo launchctl disable "system/$label"
      fi
      ;;
  esac
}

install_portable_launcher() {
  local logical=$1 source=$2 changed_variable=$3

  ensure_root_directory "$PORTABLE_LAUNCHER_DIR" 755
  install_root_file_if_changed "$source" "$PORTABLE_LAUNCHER_DIR/$logical" \
    755 "$changed_variable"
}

install_portable_service() {
  local logical=$1 changed_variable=$2 portable rc_name label source target mode

  portable=$(portable_service_name "$logical")
  rc_name=$(freebsd_service_name "$logical")
  label=$(launchd_service_label "$logical")
  case $SERVICE_MANAGER in
    openrc)
      source=$rendered/openrc-$portable
      target=/etc/init.d/$portable
      mode=755
      ;;
    runit)
      source=$rendered/runit-$portable.run
      target=/etc/sv/$portable/run
      mode=755
      ;;
    freebsd)
      source=$rendered/freebsd-$rc_name
      target=/usr/local/etc/rc.d/$rc_name
      mode=555
      ;;
    launchd)
      source=$rendered/launchd-$label.plist
      target=/Library/LaunchDaemons/$label.plist
      mode=644
      ;;
    *) die "portable service installation called for $SERVICE_MANAGER" ;;
  esac
  install_root_file_if_changed "$source" "$target" "$mode" "$changed_variable"
}

legacy_cloudflared_service_present() {
  [[ $SERVICE_MANAGER == systemd ]] || return 1
  sudo systemctl cat cloudflared.service 2>/dev/null | grep -q -- '--token'
}

cloudflared_supports_token_file() {
  local help_file=$WORK_DIR/cloudflared-tunnel-run.help

  if [[ ! -f $help_file ]]; then
    "$CLOUDFLARED_BIN" tunnel run --help >"$help_file" 2>&1 || return 1
  fi
  grep -Fq -- '--token-file' "$help_file"
}

validate_cloudflare_token() {
  local token=$1

  ((${#token} >= 100)) || die "Cloudflare tunnel token is unexpectedly short"
  [[ $token == eyJ* ]] || die "Cloudflare tunnel token should begin with eyJ"
  [[ $token != *[[:space:]]* ]] || die "Cloudflare tunnel token contains whitespace"
}

validate_cloudflare_api_token() {
  local token=$1

  [[ -n $token ]] || die "Cloudflare API token is empty"
  [[ $token != *[[:space:]]* ]] || die "Cloudflare API token contains whitespace"
}

prepare_cloudflare_api_token() {
  local token=$CLOUDFLARE_API_TOKEN_ENV api_token_changed=0
  local api_token_copy=$WORK_DIR/cloudflare-management-api.token

  if [[ -n $CLOUDFLARE_API_TOKEN_INPUT ]]; then
    [[ -r $CLOUDFLARE_API_TOKEN_INPUT ]] ||
      die "cannot read Cloudflare API token file: $CLOUDFLARE_API_TOKEN_INPUT"
    token=$(tr -d '\r\n' < "$CLOUDFLARE_API_TOKEN_INPUT")
  fi
  if [[ -z $token ]] && ! sudo test -s "$CLOUDFLARE_API_TOKEN_TARGET"; then
    if ((NON_INTERACTIVE)); then
      die "remotely managed tunnel routing is not verifiable; provide" \
        "CLOUDFLARE_API_TOKEN or --cloudflare-api-token-file with Account /" \
        "Cloudflare Tunnel / Edit, Zone / Zone / Read, and Zone / DNS / Edit permissions"
    fi
    [[ -r /dev/tty ]] || die "a terminal is required to enter the Cloudflare API token"
    cat >&2 <<'EOF'
Cloudflare requires a separate management API token to provision and verify
the remotely managed tunnel's public ingress and hostname DNS associations.
Create a token scoped to this account and keelanwatlington.com with Account /
Cloudflare Tunnel / Edit, Zone / Zone / Read, and Zone / DNS / Edit.
EOF
    IFS= read -r -s -p "Cloudflare Tunnel/DNS API token: " token < /dev/tty
    printf '\n' > /dev/tty
  fi
  if [[ -z $token ]] && ! sudo test -s "$CLOUDFLARE_API_TOKEN_TARGET"; then
    die "Cloudflare API token was not provided"
  fi

  if [[ -n $token ]]; then
    validate_cloudflare_api_token "$token"
    printf '%s\n' "$token" > "$api_token_copy"
    chmod 0600 "$api_token_copy"
    ensure_root_directory /etc/cloudflared 755
    install_root_file_if_changed "$api_token_copy" \
      "$CLOUDFLARE_API_TOKEN_TARGET" 600 api_token_changed
    if ((api_token_changed)); then
      printf 'Installed protected Cloudflare Tunnel API token.\n'
    else
      printf 'Reusing protected Cloudflare Tunnel API token.\n'
    fi
  else
    printf 'Reusing protected Cloudflare Tunnel API token.\n'
  fi
  unset token CLOUDFLARE_API_TOKEN_ENV

  sudo install -m 0600 -o "$SITE_USER" -g "$SITE_GROUP" \
    "$CLOUDFLARE_API_TOKEN_TARGET" "$api_token_copy"
}

reconcile_cloudflare_public_routing() {
  local connector_token_copy=$WORK_DIR/cloudflare-connector.token
  local api_token_copy=$WORK_DIR/cloudflare-management-api.token

  prepare_cloudflare_api_token
  sudo install -m 0600 -o "$SITE_USER" -g "$SITE_GROUP" \
    "$CLOUDFLARE_TOKEN_TARGET" "$connector_token_copy"
  PYTHONDONTWRITEBYTECODE=1 "$PYTHON_BIN" \
    "$SERVER_ROOT/configure_cloudflare_tunnel.py" \
    --connector-token-file "$connector_token_copy" \
    --api-token-file "$api_token_copy" \
    --expected-tunnel-id "$CLOUDFLARE_TUNNEL_ID" \
    --zone-name "$CLOUDFLARE_APEX_HOSTNAME" \
    --hostname "$CLOUDFLARE_APEX_HOSTNAME" \
    --hostname "$CLOUDFLARE_WWW_HOSTNAME" \
    --service "http://localhost${SITE_ADDRESS}"
  rm -f -- "$connector_token_copy" "$api_token_copy"
}

configure_cloudflared() {
  local mode= token=$CLOUDFLARE_TOKEN_ENV source_config existing_credentials

  ((ENABLE_CLOUDFLARE)) || {
    CLOUDFLARE_MODE=disabled
    unset CLOUDFLARE_API_TOKEN_ENV
    return 0
  }
  if [[ -n $CLOUDFLARE_TOKEN_INPUT ]]; then
    [[ -r $CLOUDFLARE_TOKEN_INPUT ]] || die "cannot read Cloudflare token file: $CLOUDFLARE_TOKEN_INPUT"
    token=$(tr -d '\r\n' < "$CLOUDFLARE_TOKEN_INPUT")
  fi

  if [[ -n $token ]]; then
    mode=token
  elif [[ -n $CLOUDFLARE_CONFIG_IMPORT || -n $CLOUDFLARE_CREDENTIALS_IMPORT ]]; then
    mode=imported-config
  elif sudo test -s "$CLOUDFLARE_CONFIG_TARGET"; then
    mode=existing-config
  elif sudo test -s "$CLOUDFLARE_TOKEN_TARGET"; then
    mode=installed-token
  elif legacy_cloudflared_service_present; then
    mode=existing-service
  elif ((NON_INTERACTIVE)); then
    die "Cloudflare tunnel configuration is missing; provide CLOUDFLARED_TUNNEL_TOKEN or --cloudflare-token-file"
  else
    [[ -r /dev/tty ]] || die "a terminal is required to enter the Cloudflare tunnel token"
    IFS= read -r -s -p "Cloudflare tunnel token (from Add a replica): " token < /dev/tty
    printf '\n' > /dev/tty
    mode=token
  fi

  case $mode in
    token)
      cloudflared_supports_token_file ||
        die "installed cloudflared does not support protected --token-file tunnel credentials"
      validate_cloudflare_token "$token"
      printf '%s\n' "$token" > "$WORK_DIR/cloudflared.token"
      chmod 0600 "$WORK_DIR/cloudflared.token"
      ensure_root_directory /etc/cloudflared 755
      install_root_file_if_changed "$WORK_DIR/cloudflared.token" \
        "$CLOUDFLARE_TOKEN_TARGET" 600 CLOUDFLARE_CHANGED
      CLOUDFLARE_MODE=token
      unset token CLOUDFLARE_TOKEN_ENV
      printf 'Installed protected Cloudflare tunnel token.\n'
      ;;
    installed-token)
      cloudflared_supports_token_file ||
        die "installed cloudflared does not support protected --token-file tunnel credentials"
      CLOUDFLARE_MODE=token
      printf 'Reusing protected Cloudflare tunnel token.\n'
      ;;
    imported-config)
      source_config=$rendered/cloudflared-config.yml
      sudo "$CLOUDFLARED_BIN" --config "$source_config" tunnel ingress validate
      ensure_root_directory /etc/cloudflared 755
      install_root_file_if_changed "$CLOUDFLARE_CREDENTIALS_IMPORT" \
        "$CLOUDFLARE_CREDENTIALS_TARGET" 600 CLOUDFLARE_CHANGED
      install_root_file_if_changed "$source_config" "$CLOUDFLARE_CONFIG_TARGET" \
        644 CLOUDFLARE_CHANGED
      CLOUDFLARE_MODE=local
      printf 'Restored protected locally managed Cloudflare tunnel state.\n'
      ;;
    existing-config)
      existing_credentials=$(sudo "$PYTHON_BIN" - "$CLOUDFLARE_CONFIG_TARGET" <<'PY'
import sys
from pathlib import Path

config = Path(sys.argv[1])
matches = []
for line in config.read_text(encoding="utf-8").splitlines():
    key, separator, value = line.strip().partition(":")
    if separator and key == "credentials-file":
        matches.append(value.strip().strip("'\""))
if len(matches) != 1 or not Path(matches[0]).is_absolute():
    raise SystemExit(f"expected one absolute credentials-file entry in {config}")
print(matches[0])
PY
      )
      if [[ $existing_credentials != "$CLOUDFLARE_CREDENTIALS_TARGET" ]]; then
        sudo test -f "$existing_credentials" ||
          die "Cloudflare credentials file is missing: $existing_credentials"
        sudo cat "$CLOUDFLARE_CONFIG_TARGET" > "$WORK_DIR/cloudflared-existing.yml"
        "$PYTHON_BIN" - "$SERVER_ROOT" "$WORK_DIR/cloudflared-existing.yml" \
          "$WORK_DIR/cloudflared-existing-relocated.yml" \
          "$CLOUDFLARE_CREDENTIALS_TARGET" <<'PY'
import sys
from pathlib import Path

sys.path.insert(0, sys.argv[1])
from render_server_config import render_cloudflared_config

render_cloudflared_config(
    Path(sys.argv[2]),
    Path(sys.argv[3]),
    credentials_file=Path(sys.argv[4]),
)
PY
        install_root_file_if_changed "$existing_credentials" \
          "$CLOUDFLARE_CREDENTIALS_TARGET" 600 CLOUDFLARE_CHANGED
        install_root_file_if_changed "$WORK_DIR/cloudflared-existing-relocated.yml" \
          "$CLOUDFLARE_CONFIG_TARGET" 644 CLOUDFLARE_CHANGED
        printf 'Relocated the legacy Cloudflare credential into protected system storage.\n'
      fi
      sudo "$CLOUDFLARED_BIN" --config "$CLOUDFLARE_CONFIG_TARGET" \
        tunnel ingress validate
      CLOUDFLARE_MODE=local
      printf 'Preserving existing Cloudflare tunnel configuration.\n'
      ;;
    existing-service)
      [[ $SERVICE_MANAGER == systemd ]] || die "an external tunnel service can only be preserved under systemd"
      CLOUDFLARE_MODE=external
      printf 'Preserving existing externally configured Cloudflare tunnel service.\n'
      ;;
  esac
  if [[ $CLOUDFLARE_MODE == token ]]; then
    reconcile_cloudflare_public_routing
  fi
  unset CLOUDFLARE_TOKEN_ENV CLOUDFLARE_API_TOKEN_ENV
}

[[ -z $STORE_ENV_IMPORT || -r $STORE_ENV_IMPORT ]] || die "cannot read store environment backup: $STORE_ENV_IMPORT"
[[ -z $ORDERS_DB_IMPORT || -r $ORDERS_DB_IMPORT ]] || die "cannot read order database backup: $ORDERS_DB_IMPORT"
if ((ENABLE_CLOUDFLARE)) &&
   [[ -n $CLOUDFLARE_CONFIG_IMPORT || -n $CLOUDFLARE_CREDENTIALS_IMPORT ]]; then
  [[ -n $CLOUDFLARE_CONFIG_IMPORT && -n $CLOUDFLARE_CREDENTIALS_IMPORT ]] ||
    die "both Cloudflare config and credentials are required for a local tunnel restore"
  [[ -r $CLOUDFLARE_CONFIG_IMPORT ]] || die "cannot read Cloudflare config backup: $CLOUDFLARE_CONFIG_IMPORT"
  [[ -r $CLOUDFLARE_CREDENTIALS_IMPORT ]] || die "cannot read Cloudflare credentials backup: $CLOUDFLARE_CREDENTIALS_IMPORT"
fi

sudo -v
install_core_packages
PYTHON_BIN=$(command -v python3)
CADDY_BIN=$(command -v caddy)
if ((ENABLE_CLOUDFLARE)); then
  install_cloudflared_package
  CLOUDFLARED_BIN=$(command -v cloudflared)
else
  CLOUDFLARED_BIN=$(command -v cloudflared 2>/dev/null || printf '%s\n' /usr/bin/cloudflared)
fi

PYTHONDONTWRITEBYTECODE=1 \
  "$PYTHON_BIN" "$SERVER_ROOT/verify_site.py" --site-root "$SITE_ROOT"
PYTHONDONTWRITEBYTECODE=1 \
  "$PYTHON_BIN" -m unittest discover -s "$SITE_ROOT/tools" -p 'test_*.py'

ensure_private_directory "$CONFIG_DIR"
ensure_private_directory "$STATE_DIR"

if [[ -f $ENV_FILE ]]; then
  cp "$ENV_FILE" "$WORK_DIR/store.env.before"
  chmod 0600 "$WORK_DIR/store.env.before"
fi
if [[ -n $STORE_ENV_IMPORT && $STORE_ENV_IMPORT != "$ENV_FILE" ]]; then
  install_user_file_if_changed "$STORE_ENV_IMPORT" "$ENV_FILE" 600 STORE_CHANGED
elif [[ ! -e $ENV_FILE ]] && sudo test -f /etc/keelanwatlington-store.env; then
  sudo install -m 0600 -o "$SITE_USER" -g "$SITE_GROUP" \
    /etc/keelanwatlington-store.env "$ENV_FILE"
  STORE_CHANGED=1
fi

configure_store_args=(
  --env-file "$ENV_FILE"
  --site-root "$SITE_ROOT"
  --state-dir "$STATE_DIR"
  --site-origin "$PUBLIC_ORIGIN"
)
((NON_INTERACTIVE)) && configure_store_args+=(--non-interactive)
"$PYTHON_BIN" "$SERVER_ROOT/configure_store.py" "${configure_store_args[@]}"
if [[ ! -f $WORK_DIR/store.env.before ]] || ! cmp -s "$WORK_DIR/store.env.before" "$ENV_FILE"; then
  STORE_CHANGED=1
fi

rendered=$WORK_DIR/rendered
render_args=(
  --output "$rendered"
  --site-root "$SITE_ROOT"
  --home "$SITE_HOME"
  --user "$SITE_USER"
  --group "$SITE_GROUP"
  --site-address "$SITE_ADDRESS"
  --python-bin "$PYTHON_BIN"
  --caddy-bin "$CADDY_BIN"
  --cloudflared-bin "$CLOUDFLARED_BIN"
  --cloudflared-token-file "$CLOUDFLARE_TOKEN_TARGET"
)
if [[ -n $CLOUDFLARE_CONFIG_IMPORT ]]; then
  render_args+=(
    --cloudflared-local-config "$CLOUDFLARE_CONFIG_IMPORT"
    --cloudflared-local-credentials-file "$CLOUDFLARE_CREDENTIALS_TARGET"
  )
fi
"$PYTHON_BIN" "$SERVER_ROOT/render_server_config.py" "${render_args[@]}"
configure_cloudflared

if [[ $SERVICE_MANAGER == systemd ]] && command -v systemd-analyze >/dev/null 2>&1; then
  systemd-analyze verify \
    "$rendered/keelanwatlington-store.service" \
    "$rendered/keelanwatlington-blog-sync.service" \
    "$rendered/keelanwatlington-blog-sync.timer" \
    "$rendered/cloudflared-token.service" \
    "$rendered/cloudflared-local.service"
fi

sudo env SITE_ROOT="$SITE_ROOT" SITE_ADDRESS="$SITE_ADDRESS" \
  "$CADDY_BIN" validate --config "$SERVER_ROOT/Caddyfile.production"

store_hash_files=("$SITE_ROOT/tools/store_fulfillment.py")
[[ $SERVICE_MANAGER == systemd ]] || store_hash_files+=("$SITE_ROOT/tools/run_store.py")
store_code_hash=$("$PYTHON_BIN" - "${store_hash_files[@]}" <<'PY'
import hashlib
import sys

digest = hashlib.sha256()
for name in sys.argv[1:]:
    with open(name, "rb") as source:
        digest.update(source.read())
print(digest.hexdigest())
PY
)
if [[ ! -f $STORE_CODE_MARKER ]] || [[ $(<"$STORE_CODE_MARKER") != "$store_code_hash" ]]; then
  STORE_CHANGED=1
fi

if [[ -n $ORDERS_DB_IMPORT ]]; then
  "$PYTHON_BIN" - "$ORDERS_DB_IMPORT" <<'PY'
import sqlite3
import sys

database = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
try:
    result = database.execute("PRAGMA quick_check").fetchone()
finally:
    database.close()
if not result or result[0] != "ok":
    raise SystemExit("order database backup failed SQLite integrity validation")
PY
  if [[ $ORDERS_DB_IMPORT != "$ORDERS_DB" ]]; then
    if [[ ! -f $ORDERS_DB || $(stat_mode "$ORDERS_DB") != 600 ||
          $(stat_uid "$ORDERS_DB") != "$SITE_UID" ||
          $(stat_gid "$ORDERS_DB") != "$SITE_GID" ]] ||
       ! cmp -s "$ORDERS_DB_IMPORT" "$ORDERS_DB"; then
      stop_service store
      install -m 0600 "$ORDERS_DB_IMPORT" "$STATE_DIR/.orders.sqlite3.import"
      mv "$STATE_DIR/.orders.sqlite3.import" "$ORDERS_DB"
      STORE_CHANGED=1
    fi
  elif [[ $(stat_mode "$ORDERS_DB") != 600 ]]; then
    chmod 0600 "$ORDERS_DB"
    STORE_CHANGED=1
  fi
elif [[ ! -e $ORDERS_DB ]] && sudo test -f /var/lib/keelanwatlington/store/orders.sqlite3; then
  stop_service store
  sudo install -m 0600 -o "$SITE_USER" -g "$SITE_GROUP" \
    /var/lib/keelanwatlington/store/orders.sqlite3 "$ORDERS_DB"
  STORE_CHANGED=1
fi

ensure_root_directory /etc/caddy 755
install_root_file_if_changed "$SERVER_ROOT/Caddyfile.production" \
  /etc/caddy/Caddyfile 644 CADDY_CHANGED

if [[ $SERVICE_MANAGER == systemd ]]; then
  ensure_root_directory /etc/systemd/system/caddy.service.d 755
  install_root_file_if_changed "$rendered/caddy.service.conf" \
    /etc/systemd/system/caddy.service.d/website.conf 644 CADDY_CHANGED SYSTEMD_CHANGED
  install_root_file_if_changed "$rendered/keelanwatlington-store.service" \
    /etc/systemd/system/keelanwatlington-store.service 644 STORE_CHANGED SYSTEMD_CHANGED
  install_root_file_if_changed "$rendered/keelanwatlington-blog-sync.service" \
    /etc/systemd/system/keelanwatlington-blog-sync.service 644 BLOG_CHANGED SYSTEMD_CHANGED
  install_root_file_if_changed "$rendered/keelanwatlington-blog-sync.timer" \
    /etc/systemd/system/keelanwatlington-blog-sync.timer 644 BLOG_CHANGED SYSTEMD_CHANGED
  if ((ENABLE_CLOUDFLARE)) && [[ $CLOUDFLARE_MODE != external ]]; then
    cloud_service_source=$rendered/cloudflared-token.service
    [[ $CLOUDFLARE_MODE != local ]] || cloud_service_source=$rendered/cloudflared-local.service
    install_root_file_if_changed "$cloud_service_source" \
      /etc/systemd/system/cloudflared.service 644 CLOUDFLARE_CHANGED SYSTEMD_CHANGED
  fi
else
  install_portable_launcher caddy "$rendered/launcher-caddy" CADDY_CHANGED
  install_portable_launcher store "$rendered/launcher-store" STORE_CHANGED
  install_portable_launcher blog "$rendered/launcher-blog" BLOG_CHANGED
  install_portable_service caddy CADDY_CHANGED
  install_portable_service store STORE_CHANGED
  install_portable_service blog BLOG_CHANGED
  if ((ENABLE_CLOUDFLARE)); then
    [[ $CLOUDFLARE_MODE != external ]] || die "portable services cannot preserve an opaque external Cloudflare command"
    cloud_launcher_source=$rendered/launcher-cloudflared-token
    [[ $CLOUDFLARE_MODE != local ]] || cloud_launcher_source=$rendered/launcher-cloudflared-local
    install_portable_launcher cloudflared "$cloud_launcher_source" CLOUDFLARE_CHANGED
    install_portable_service cloudflared CLOUDFLARE_CHANGED
  fi
fi

if [[ $SERVICE_MANAGER == systemd ]]; then
  if ! getfacl -cp "$SITE_HOME" 2>/dev/null | grep -qx 'user:caddy:--x'; then
    sudo setfacl -m "u:caddy:--x" "$SITE_HOME"
  fi
  sudo -u caddy test -r "$SITE_ROOT/index.html" ||
    die "the caddy user cannot read $SITE_ROOT/index.html; check checkout permissions"
else
  [[ -r $SITE_ROOT/index.html ]] || die "$SITE_USER cannot read $SITE_ROOT/index.html"
fi

((SYSTEMD_CHANGED == 0)) || sudo systemctl daemon-reload
ensure_service_enabled store
ensure_service_enabled caddy
start_or_restart_service store "$STORE_CHANGED"
start_or_restart_service caddy "$CADDY_CHANGED"
if ((ENABLE_BLOG_TIMER)); then
  ensure_service_enabled blog
  start_or_restart_service blog "$BLOG_CHANGED"
else
  disable_service blog
fi
if ((ENABLE_CLOUDFLARE)); then
  ensure_service_enabled cloudflared
  start_or_restart_service cloudflared "$CLOUDFLARE_CHANGED"
fi

verify_installed_stack

printf '%s\n' "$store_code_hash" > "$WORK_DIR/store-code.sha256"
marker_changed=0
install_user_file_if_changed "$WORK_DIR/store-code.sha256" \
  "$STORE_CODE_MARKER" 600 marker_changed

printf '\nKeelan'"'"'s Networking Trident: website prong ready.\n'
printf '  platform:      %s (%s)\n' "$PLATFORM_FAMILY" "$SERVICE_MANAGER"
printf '  checkout:      %s\n' "$SITE_ROOT"
printf '  store config:  %s\n' "$ENV_FILE"
printf '  order state:   %s\n' "$ORDERS_DB"
printf '  local origin:  http://127.0.0.1%s\n' "$SITE_ADDRESS"
if ((ENABLE_CLOUDFLARE)); then
  printf '  public origin: %s\n' "$PUBLIC_ORIGIN"
fi
