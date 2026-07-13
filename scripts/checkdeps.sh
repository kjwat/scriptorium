#!/usr/bin/env bash
set -u

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"

missing_required=()
missing_runtime=()
missing_optional=()

have_cmd() { command -v "$1" >/dev/null 2>&1; }
have_pkgconfig() { pkg-config --exists "$1" >/dev/null 2>&1; }

add_missing() {
    case "$1" in
        required) missing_required+=("$2") ;;
        runtime)  missing_runtime+=("$2") ;;
        optional) missing_optional+=("$2") ;;
    esac
}

dep_hint() {
    case "$1" in
        cc) echo "provided by gcc or clang" ;;
        make) echo "provided by make/build tools" ;;
        python3) echo "used by simplebrowse JavaScript mode helper" ;;
        pkg-config) echo "provided by pkg-config or pkgconf" ;;
        xdg-open) echo "Linux desktop helper; provided by xdg-utils; used by simplefiles external-open" ;;
        open) echo "macOS built-in external-open helper" ;;
        pdftotext) echo "provided by poppler/poppler-utils; used by simplepdf" ;;
        pandoc) echo "provided by pandoc; used by simplepdf EPUB support" ;;
        mpv) echo "used by audio apps and reminder playback" ;;
        git) echo "used by simplever" ;;
        mbsync) echo "provided by isync; used by simplemail synchronization" ;;
        msmtp) echo "used by simplemail sending" ;;
        curl) echo "command-line HTTP client used during setup and maintenance" ;;
        calcurse) echo "standalone calendar covered by the managed calcurse config" ;;
        rsync) echo "used by Scriptorium file synchronization workflows" ;;
        pactl|parec) echo "used by simplevis audio capture; provided by pulseaudio-utils/libpulse" ;;
        zip) echo "used by simplefiles :compress" ;;
        unzip) echo "used by simplefiles :extract" ;;
        tar) echo "used by simplefiles :extract for TAR archives" ;;
        findmnt) echo "provided by util-linux; used by simplefiles :unmount validation" ;;
        udisksctl) echo "provided by udisks2; used by simplefiles :unmount" ;;
        umount) echo "provided by util-linux; fallback for simplefiles :unmount" ;;
        crontab) echo "cron fallback for SimpleCal/SimpleClock reminders when systemd user services are unavailable" ;;
        file) echo "optional helper for file type detection" ;;
        less) echo "optional pager" ;;
        fzf) echo "used by simplepdf fuzzy file selection" ;;
        links) echo "default terminal browser used by simplenews; configurable" ;;
        gio) echo "provided by glib; used by simplefiles desktop open/trash/unmount features" ;;
        wl-copy|wl-paste) echo "provided by wl-clipboard; used by simplewords Wayland clipboard" ;;
        xclip|xsel) echo "used by simplewords X11 clipboard" ;;
        *) echo "provided by $1" ;;
    esac
}

pc_hint() {
    case "$1" in
        ncursesw) echo "provided by ncurses development package" ;;
        gio-2.0) echo "provided by GLib/GIO development package; used by simplefiles removable-volume discovery" ;;
        libcurl) echo "provided by libcurl/curl development package; used by simplebrowse, simplepod, and simplenews" ;;
        openssl) echo "provided by OpenSSL development package; used by simplepod PodcastIndex authentication" ;;
    esac
}

js_pkg_hint() {
    case "$family" in
        debian) echo "python3 python3-gi gir1.2-gtk-3.0 gir1.2-webkit2-4.1" ;;
        arch) echo "python python-gobject webkit2gtk-4.1" ;;
        fedora) echo "python3 python3-gobject webkit2gtk4.1" ;;
        alpine) echo "python3 py3-gobject3 webkit2gtk-4.1" ;;
        void) echo "python3 python3-gobject libwebkit2gtk41" ;;
        suse) echo "python3 python3-gobject typelib-1_0-Gtk-3_0 typelib-1_0-WebKit2-4_1" ;;
        macos) echo "not available through Homebrew on macOS; use SimpleBrowse reader mode" ;;
        *) echo "python3 python3-gobject WebKit2GTK-4.1 introspection" ;;
    esac
}

check_simplebrowse_js() {
    if ! have_cmd python3; then
        printf "MISSING: %-16s (%s; %s)\n" "SimpleBrowse JS" "python3" "$(dep_hint python3)"
        add_missing optional "SimpleBrowse JS: $(js_pkg_hint)"
        return
    fi

    if python3 - <<'PY' >/dev/null 2>&1
import gi
gi.require_version("Gtk", "3.0")
gi.require_version("WebKit2", "4.1")
from gi.repository import Gtk, WebKit2
PY
    then
        printf "FOUND:   %-16s (%s)\n" "SimpleBrowse JS" "WebKitGTK 4.1 via Python GI"
    else
        printf "MISSING: %-16s (%s)\n" "SimpleBrowse JS" "$(js_pkg_hint)"
        add_missing optional "SimpleBrowse JS: $(js_pkg_hint)"
    fi
}

check_cmd() {
    bucket="$1"
    cmd="$2"
    label="$3"

    if have_cmd "$cmd"; then
        printf "FOUND:   %-16s (%s)\n" "$label" "$cmd"
    else
        printf "MISSING: %-16s (%s; %s)\n" "$label" "$cmd" "$(dep_hint "$cmd")"
        add_missing "$bucket" "$label"
    fi
}

is_gnu_make() {
    "$1" --version 2>/dev/null | grep -q 'GNU Make'
}

check_make() {
    if [ "$family" = macos ]; then
        if have_cmd make && is_gnu_make make; then
            printf "FOUND:   %-16s (%s)\n" "GNU make" "make"
        elif have_cmd gmake && is_gnu_make gmake; then
            printf "FOUND:   %-16s (%s)\n" "GNU make" "gmake"
        else
            printf "MISSING: %-16s (%s)\n" "GNU make" "brew install make"
            add_missing required "GNU make"
        fi
    else
        check_cmd required make "make"
    fi
}

check_pc() {
    bucket="$1"
    pc="$2"
    label="$3"

    if have_pkgconfig "$pc"; then
        printf "FOUND:   %-16s (pkg-config: %s)\n" "$label" "$pc"
    else
        printf "MISSING: %-16s (pkg-config: %s; %s)\n" "$label" "$pc" "$(pc_hint "$pc")"
        add_missing "$bucket" "$label"
    fi
}

check_any_editor() {
    if have_cmd nano || have_cmd vim || have_cmd nvim || have_cmd emacs || have_cmd micro; then
        printf "FOUND:   %-16s " "external editor"
        first=1
        for ed in nano vim nvim emacs micro; do
            if have_cmd "$ed"; then
                if [ "$first" -eq 1 ]; then
                    printf "(%s" "$ed"
                    first=0
                else
                    printf ", %s" "$ed"
                fi
            fi
        done
        printf ")\n"
    else
        echo "MISSING: external editor  (optional; nano recommended)"
        add_missing optional "external editor"
    fi
}

configure_homebrew_pkgconfig() {
    [ "$family" = macos ] || return 0
    have_cmd brew || return 0

    for formula in ncurses curl openssl@3; do
        formula_prefix="$(brew --prefix "$formula" 2>/dev/null)" || continue
        pkgconfig_dir="$formula_prefix/lib/pkgconfig"
        [ -d "$pkgconfig_dir" ] || continue
        case ":${PKG_CONFIG_PATH:-}:" in
            *":$pkgconfig_dir:"*) ;;
            *) PKG_CONFIG_PATH="$pkgconfig_dir${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}" ;;
        esac
    done
    export PKG_CONFIG_PATH
}

detect_platform() {
    os="$(uname -s 2>/dev/null || echo unknown)"
    distro="unknown"
    family="$("$ROOT/scripts/detect-platform.sh")"
    wsl=0

    case "$os" in
        Darwin) distro="macos"; return ;;
        MINGW*|MSYS*|CYGWIN*) distro="windows"; return ;;
    esac

    if grep -qi microsoft /proc/version 2>/dev/null; then
        wsl=1
    fi

    if [ -r /etc/os-release ]; then
        distro="$(awk -F= '
            $1 == "ID" {
                value = substr($0, index($0, "=") + 1)
                gsub(/^['\''"]|['\''"]$/, "", value)
                print value
                exit
            }
        ' /etc/os-release)"
        [ -n "$distro" ] || distro=unknown
    fi
}

pkg_for_dep() {
    case "$family:$1" in
        *:fzf) echo "fzf" ;;
        *:zip) echo "zip" ;;
        *:unzip) echo "unzip" ;;
        *:tar) echo "tar" ;;
        *:file)
            case "$family" in
                macos) echo "libmagic" ;;
                *) echo "file" ;;
            esac
            ;;
        *:less) echo "less" ;;
        *:calcurse) echo "calcurse" ;;
        *:rsync) echo "rsync" ;;
        *:xdg-open) echo "xdg-utils" ;;
        *:findmnt) echo "util-linux" ;;
        *:udisksctl) echo "udisks2" ;;
        *:crontab)
            case "$family" in
                alpine) echo "dcron" ;;
                arch | fedora | void) echo "cronie" ;;
                *) echo "cron" ;;
            esac
            ;;
        *:pactl|*:parec)
            case "$family" in
                arch) echo "libpulse" ;;
                macos) echo "pulseaudio" ;;
                *) echo "pulseaudio-utils" ;;
            esac
            ;;
        *:links) echo "links" ;;
        *:gio)
            case "$family" in
                debian) echo "libglib2.0-bin" ;;
                arch|fedora) echo "glib2" ;;
                suse) echo "glib2-tools" ;;
                *) echo "glib" ;;
            esac
            ;;
        *:wl-copy|*:wl-paste) echo "wl-clipboard" ;;
        *:xclip) echo "xclip" ;;
        *:xsel) echo "xsel" ;;
        *:"SimpleBrowse JS:"*) js_pkg_hint ;;
        *) echo "" ;;
    esac
}


packages_for_family() {
    case "$family" in
        void)
            INSTALL="sudo xbps-install -Sy"
            PKG_REQUIRED="base-devel pkg-config ncurses-devel glib-devel libcurl-devel openssl-devel"
            PKG_RUNTIME="git mpv poppler-utils pandoc isync msmtp calcurse links curl ca-certificates rsync"
            PKG_OPTIONAL="nano zip unzip tar xdg-utils file less fzf pulseaudio-utils glib util-linux udisks2 wl-clipboard xclip xsel python3 python3-gobject libwebkit2gtk41 cronie"
            ;;
        debian)
            INSTALL="sudo apt-get update && sudo apt-get install -y"
            PKG_REQUIRED="build-essential pkg-config libncurses-dev libglib2.0-dev libcurl4-openssl-dev libssl-dev"
            PKG_RUNTIME="git mpv poppler-utils pandoc isync msmtp calcurse links curl ca-certificates rsync"
            PKG_OPTIONAL="nano zip unzip tar xdg-utils file less fzf pulseaudio-utils libglib2.0-bin util-linux udisks2 wl-clipboard xclip xsel python3 python3-gi gir1.2-gtk-3.0 gir1.2-webkit2-4.1 cron"
            ;;
        arch)
            INSTALL="sudo pacman -Syu --needed"
            PKG_REQUIRED="base-devel pkgconf ncurses glib2 curl openssl"
            PKG_RUNTIME="git mpv poppler pandoc-cli isync msmtp calcurse links ca-certificates rsync"
            PKG_OPTIONAL="nano zip unzip tar xdg-utils file less fzf libpulse pipewire-jack util-linux udisks2 wl-clipboard xclip xsel python python-gobject webkit2gtk-4.1 cronie"
            ;;
        fedora)
            INSTALL="sudo dnf install -y"
            PKG_REQUIRED="gcc make pkgconf-pkg-config ncurses-devel glib2-devel libcurl-devel openssl-devel"
            PKG_RUNTIME="git mpv poppler-utils pandoc isync msmtp calcurse links curl ca-certificates rsync"
            PKG_OPTIONAL="nano zip unzip tar xdg-utils file less fzf pulseaudio-utils glib2 util-linux udisks2 wl-clipboard xclip xsel python3 python3-gobject webkit2gtk4.1 cronie"
            ;;
        alpine)
            INSTALL="sudo apk add"
            PKG_REQUIRED="build-base bash pkgconf ncurses-dev glib-dev curl-dev openssl-dev"
            PKG_RUNTIME="git mpv poppler-utils pandoc isync msmtp calcurse links curl ca-certificates rsync"
            PKG_OPTIONAL="nano zip unzip tar xdg-utils file less fzf pulseaudio-utils glib util-linux udisks2 wl-clipboard xclip xsel python3 py3-gobject3 webkit2gtk-4.1 dcron"
            ;;
        suse)
            INSTALL="sudo zypper install"
            PKG_REQUIRED="gcc make pkg-config ncurses-devel glib2-devel libcurl-devel libopenssl-devel"
            PKG_RUNTIME="git mpv poppler-tools pandoc isync msmtp calcurse links curl ca-certificates rsync"
            PKG_OPTIONAL="nano zip unzip tar xdg-utils file less fzf pulseaudio-utils glib2-tools util-linux udisks2 wl-clipboard xclip xsel python3 python3-gobject typelib-1_0-Gtk-3_0 typelib-1_0-WebKit2-4_1 cron"
            ;;
        macos)
            INSTALL="brew install"
            PKG_REQUIRED="pkgconf ncurses curl make openssl@3 glib"
            PKG_RUNTIME="git mpv poppler pandoc isync msmtp calcurse links rsync"
            PKG_OPTIONAL="nano zip unzip libmagic less fzf pulseaudio"
            ;;
        msys2)
            INSTALL="pacman -S --needed"
            PKG_REQUIRED="base-devel mingw-w64-x86_64-toolchain mingw-w64-x86_64-pkgconf mingw-w64-x86_64-ncurses mingw-w64-x86_64-curl"
            PKG_RUNTIME="git mingw-w64-x86_64-mpv mingw-w64-x86_64-poppler pandoc"
            PKG_OPTIONAL="nano zip unzip file less fzf"
            ;;
        *)
            INSTALL="# install manually:"
            PKG_REQUIRED="gcc make pkg-config ncurses-devel libcurl-devel libopenssl-devel"
            PKG_RUNTIME="git mpv poppler-utils pandoc"
            PKG_OPTIONAL="nano zip unzip xdg-utils file less fzf pulseaudio-utils glib wl-clipboard xclip xsel links python3 python3-gobject WebKit2GTK-4.1"
            ;;
    esac
}

echo "Checking SimpleSuite dependencies..."
echo

detect_platform
configure_homebrew_pkgconfig
packages_for_family

echo "Detected distro/platform: $distro"
echo "Detected family: $family"
[ "${wsl:-0}" = 1 ] && echo "WSL detected: yes"
echo

echo "=== Required build dependencies ==="
check_cmd required cc "C compiler"
check_make
check_cmd required pkg-config "pkg-config"
check_pc  required ncursesw "ncursesw"
check_pc  required gio-2.0 "GIO"
check_pc  required libcurl "libcurl"
check_pc  required openssl "OpenSSL"

echo
echo "=== Runtime dependencies ==="
check_cmd runtime git "git"
check_cmd runtime mpv "mpv"
check_cmd runtime pdftotext "pdftotext"
check_cmd runtime pandoc "pandoc"
check_cmd runtime mbsync "mbsync"
check_cmd runtime msmtp "msmtp"
check_cmd runtime curl "curl"

echo
echo "=== Optional / feature dependencies ==="
check_any_editor
check_cmd optional zip "zip"
check_cmd optional unzip "unzip"
check_cmd optional tar "tar"
check_cmd optional file "file"
check_cmd optional less "less"
check_cmd optional fzf "fzf"
check_cmd optional calcurse "calcurse"
check_cmd optional rsync "rsync"

if [ "$family" != "msys2" ]; then
    check_cmd optional links "links"
fi
if [ "$family" = macos ]; then
    printf "SKIPPED: %-16s (%s)\n" "SimpleBrowse JS" "WebKitGTK 4.1 is not packaged for macOS"
elif [ "$family" != msys2 ]; then
    check_simplebrowse_js
fi

if [ "$family" != "msys2" ]; then
    check_cmd optional gio "gio"
fi

if [ "$family" = "macos" ]; then
    check_cmd optional open "open"
elif [ "$family" != "msys2" ]; then
    check_cmd optional findmnt "findmnt"
    if have_cmd udisksctl || have_cmd umount; then
        if have_cmd udisksctl; then
            printf "FOUND:   %-16s (%s)\n" "unmount helper" "udisksctl"
        else
            printf "FOUND:   %-16s (%s)\n" "unmount helper" "umount"
        fi
    else
        printf "MISSING: %-16s (%s)\n" "unmount helper" "udisksctl or umount"
        add_missing optional "udisksctl"
    fi

    check_cmd optional xdg-open "xdg-open"
    check_cmd optional wl-copy "wl-copy"
    check_cmd optional wl-paste "wl-paste"

    if have_cmd xclip || have_cmd xsel; then
        if have_cmd xclip; then
            printf "FOUND:   %-16s (%s)\n" "X11 clipboard" "xclip"
        else
            printf "FOUND:   %-16s (%s)\n" "X11 clipboard" "xsel"
        fi
    else
        printf "MISSING: %-16s (%s)\n" "X11 clipboard" "xclip or xsel"
        add_missing optional "xclip"
    fi
fi

if [ "$family" != "msys2" ]; then
    check_cmd optional pactl "pactl"
    check_cmd optional parec "parec"
fi

if have_cmd systemctl && systemctl --user show-environment >/dev/null 2>&1; then
    printf "FOUND:   %-16s (%s)\n" "reminder backend" "systemd --user"
else
    check_cmd optional crontab "crontab"
fi

echo

if [ "${#missing_required[@]}" -eq 0 ] &&
   [ "${#missing_runtime[@]}" -eq 0 ] &&
   [ "${#missing_optional[@]}" -eq 0 ]; then
    echo "All checked dependencies are present."
    exit 0
fi

if [ "${#missing_required[@]}" -gt 0 ]; then
    echo "Missing REQUIRED build dependencies:"
    printf "  - %s\n" "${missing_required[@]}"
    echo
    echo "Install required packages:"
    echo "  $INSTALL $PKG_REQUIRED"
    echo
fi

if [ "${#missing_runtime[@]}" -gt 0 ]; then
    echo "Missing RUNTIME dependencies:"
    printf "  - %s\n" "${missing_runtime[@]}"
    echo
    echo "Install runtime packages:"
    echo "  $INSTALL $PKG_RUNTIME"
    echo
fi

if [ "${#missing_optional[@]}" -gt 0 ]; then
    echo "Missing OPTIONAL / feature dependencies:"
    printf "  - %s\n" "${missing_optional[@]}"
    echo

    opt_pkgs=""
    for dep in "${missing_optional[@]}"; do
        pkg="$(pkg_for_dep "$dep")"
        [ -n "$pkg" ] && opt_pkgs="$opt_pkgs $pkg"
    done

    if [ -n "$opt_pkgs" ]; then
        echo "Install optional packages:"
        echo "  $INSTALL$(printf "%s" "$opt_pkgs" | xargs)"
        echo
    fi
fi

echo "One-shot install for this platform:"
echo "  $INSTALL $PKG_REQUIRED $PKG_RUNTIME $PKG_OPTIONAL"

[ "${#missing_required[@]}" -gt 0 ] && exit 2
[ "${#missing_runtime[@]}" -gt 0 ] && exit 1
exit 0
