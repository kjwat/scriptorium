#!/bin/sh
set -eu

SERVER_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
SITE_ROOT=${WEBSITE_DIR:-$HOME/website}
EXPECTED_ROOT=$HOME/website
ORIGIN=${CADDY_CHECK_ORIGIN:-http://127.0.0.1:8080}
PYTHON_BIN=$(command -v python3 2>/dev/null || true)

# shellcheck source=platform.sh
. "$SERVER_ROOT/platform.sh"
SERVICE_MANAGER=$(website_detect_service_manager)

[ "$SITE_ROOT" = "$EXPECTED_ROOT" ] || {
  echo "error: checkout is $SITE_ROOT; expected $EXPECTED_ROOT" >&2
  exit 1
}
[ -n "$PYTHON_BIN" ] || {
  echo "error: python3 is unavailable" >&2
  exit 1
}

portable_name() {
  case "$1" in
    caddy) echo keelanwatlington-caddy ;;
    store) echo keelanwatlington-store ;;
    blog) echo keelanwatlington-blog-sync ;;
    cloudflared) echo keelanwatlington-cloudflared ;;
  esac
}

freebsd_name() {
  case "$1" in
    caddy) echo keelanwatlington_caddy ;;
    store) echo keelanwatlington_store ;;
    blog) echo keelanwatlington_blog_sync ;;
    cloudflared) echo keelanwatlington_cloudflared ;;
  esac
}

launchd_label() {
  case "$1" in
    caddy) echo com.keelanwatlington.caddy ;;
    store) echo com.keelanwatlington.store ;;
    blog) echo com.keelanwatlington.blog-sync ;;
    cloudflared) echo com.keelanwatlington.cloudflared ;;
  esac
}

service_active() {
  logical=$1
  case "$SERVICE_MANAGER" in
    systemd)
      case "$logical" in
        caddy) name=caddy.service ;;
        store) name=keelanwatlington-store.service ;;
        blog) name=keelanwatlington-blog-sync.timer ;;
        cloudflared) name=cloudflared.service ;;
      esac
      systemctl is-active --quiet "$name"
      ;;
    openrc) rc-service "$(portable_name "$logical")" status >/dev/null 2>&1 ;;
    runit) sv status "$(portable_name "$logical")" >/dev/null 2>&1 ;;
    freebsd) service "$(freebsd_name "$logical")" onestatus >/dev/null 2>&1 ;;
    launchd) launchctl print "system/$(launchd_label "$logical")" >/dev/null 2>&1 ;;
    *) echo "error: unsupported service manager: $SERVICE_MANAGER" >&2; return 1 ;;
  esac
}

"$PYTHON_BIN" "$SERVER_ROOT/verify_site.py" --site-root "$SITE_ROOT"
service_active caddy || { echo "error: Caddy service is not active" >&2; exit 1; }
service_active store || { echo "error: store service is not active" >&2; exit 1; }
if [ "${CHECK_BLOG_TIMER:-1}" -eq 1 ]; then
  service_active blog || { echo "error: blog synchronization service is not active" >&2; exit 1; }
fi
if [ "${CHECK_CLOUDFLARED:-1}" -eq 1 ]; then
  service_active cloudflared || { echo "error: Cloudflare tunnel service is not active" >&2; exit 1; }
fi

if [ "$SERVICE_MANAGER" = systemd ]; then
  store_root=$(systemctl show keelanwatlington-store.service --property=WorkingDirectory --value)
  store_command=$(systemctl show keelanwatlington-store.service --property=ExecStart --value)
  caddy_environment=$(systemctl show caddy.service --property=Environment --value)
  [ "$store_root" = "$SITE_ROOT" ] || {
    echo "error: store working directory is $store_root, not $SITE_ROOT" >&2
    exit 1
  }
  case "$store_command" in
    *"$SITE_ROOT/tools/store_fulfillment.py"*) ;;
    *) echo "error: store does not execute from $SITE_ROOT" >&2; exit 1 ;;
  esac
  case " $caddy_environment " in
    *" SITE_ROOT=$SITE_ROOT "*) ;;
    *) echo "error: Caddy SITE_ROOT is not $SITE_ROOT" >&2; exit 1 ;;
  esac
else
  caddy_launcher=/usr/local/libexec/keelanwatlington/caddy
  store_launcher=/usr/local/libexec/keelanwatlington/store
  [ -x "$caddy_launcher" ] && grep -Fq "SITE_ROOT=$SITE_ROOT" "$caddy_launcher" || {
    echo "error: portable Caddy launcher does not serve $SITE_ROOT" >&2
    exit 1
  }
  [ -x "$store_launcher" ] &&
    grep -Fq "$SITE_ROOT/tools/store_fulfillment.py" "$store_launcher" || {
    echo "error: portable store launcher does not execute from $SITE_ROOT" >&2
    exit 1
  }
fi

home_status=$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' "$ORIGIN/")
private_epub_status=$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' "$ORIGIN/editions/gleamings/dist/Gleamings.epub")
private_pdf_status=$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' "$ORIGIN/editions/gleamings/dist/Gleamings.pdf")
health=$(curl --silent --show-error "$ORIGIN/_store/health")
recovery_status=$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' "$ORIGIN/shop/recover/")

[ "$home_status" = 200 ] || { echo "error: site returned HTTP $home_status" >&2; exit 1; }
[ "$private_epub_status" = 404 ] || { echo "error: private EPUB returned HTTP $private_epub_status" >&2; exit 1; }
[ "$private_pdf_status" = 404 ] || { echo "error: private PDF returned HTTP $private_pdf_status" >&2; exit 1; }
printf '%s' "$health" | grep -q '"status":"ok"' || { echo "error: store health check failed" >&2; exit 1; }
if printf '%s' "$health" | grep -q '"recovery_email":true'; then
  [ "$recovery_status" = 200 ] || { echo "error: configured purchase recovery returned HTTP $recovery_status" >&2; exit 1; }
else
  [ "$recovery_status" = 503 ] || { echo "error: unconfigured purchase recovery returned HTTP $recovery_status" >&2; exit 1; }
fi

printf 'server verified: %s is live via %s; private editions are blocked; store is healthy\n' \
  "$SITE_ROOT" "$SERVICE_MANAGER"
