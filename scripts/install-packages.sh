#!/bin/sh
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
family="$("$ROOT/scripts/detect-platform.sh")"
package_log=
package_status_file=

platform_id() {
    if [ "$(uname -s 2>/dev/null || echo unknown)" = Darwin ]; then
        printf '%s\n' macos
        return
    fi

    [ -r /etc/os-release ] || {
        printf '%s\n' unknown
        return
    }

    awk -F= '
        $1 == "ID" {
            value = substr($0, index($0, "=") + 1)
            gsub(/^[\047"]|[\047"]$/, "", value)
            if (value ~ /^[A-Za-z0-9._-]+$/)
                print tolower(value)
            else
                print "unknown"
            found=1
            exit
        }
        END { if (!found) print "unknown" }
    ' /etc/os-release
}

distro_id="$(platform_id)"

cleanup_package_files() {
    [ -z "$package_log" ] || rm -f -- "$package_log"
    [ -z "$package_status_file" ] || rm -f -- "$package_status_file"
}

trap cleanup_package_files EXIT

have_cmd() {
    command -v "$1" >/dev/null 2>&1
}

as_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    elif have_cmd sudo; then
        sudo "$@"
    else
        printf 'Root privileges are required, but sudo is not installed.\n' >&2
        printf 'Run the installer as root or install/configure sudo first.\n' >&2
        return 127
    fi
}

have_pkgconfig() {
    pkg-config --exists "$1" >/dev/null 2>&1
}

have_any_editor() {
    have_cmd nano || have_cmd vim || have_cmd nvim || have_cmd emacs || have_cmd micro
}

have_gnu_make() {
    (have_cmd make && make --version 2>/dev/null | grep -q 'GNU Make') ||
        (have_cmd gmake && gmake --version 2>/dev/null | grep -q 'GNU Make')
}

have_reminder_scheduler() {
    have_cmd crontab ||
        (have_cmd systemctl && systemctl --user show-environment >/dev/null 2>&1)
}

configure_homebrew_pkgconfig() {
    [ "$family" = macos ] || return 0
    have_cmd brew || return 0

    for formula in ncurses curl openssl@3; do
        formula_prefix=$(brew --prefix "$formula" 2>/dev/null) || continue
        pkgconfig_dir=$formula_prefix/lib/pkgconfig
        [ -d "$pkgconfig_dir" ] || continue
        case ":${PKG_CONFIG_PATH:-}:" in
            *":$pkgconfig_dir:"*) ;;
            *) PKG_CONFIG_PATH="$pkgconfig_dir${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}" ;;
        esac
    done
    export PKG_CONFIG_PATH
}

have_simplebrowse_js() {
    have_cmd python3 || return 1

    python3 - <<'PY' >/dev/null 2>&1
import gi
gi.require_version("Gtk", "3.0")
gi.require_version("WebKit2", "4.1")
from gi.repository import Gtk, WebKit2
PY
}

dependencies_already_present() {
    for dependency_command in \
        cc pkg-config git mpv pdftotext pandoc \
        zip unzip tar file less fzf links \
        mbsync msmtp calcurse curl rsync; do
        have_cmd "$dependency_command" || return 1
    done

    case "$family" in
        macos)
            have_gnu_make || return 1
            ;;
        *)
            have_cmd make || return 1
            ;;
    esac

    have_any_editor || return 1
    have_pkgconfig ncursesw || return 1
    have_pkgconfig libcurl || return 1
    have_pkgconfig openssl || return 1
    have_pkgconfig gio-2.0 || return 1
    have_reminder_scheduler || return 1

    case "$family" in
        macos | msys2) ;;
        *)
            have_cmd python3 || return 1
            have_simplebrowse_js || return 1
            ;;
    esac

    case "$family" in
        macos)
            have_cmd open || return 1
            have_cmd pactl || return 1
            have_cmd parec || return 1
            ;;
        msys2)
            ;;
        *)
            for dependency_command in \
                xdg-open gio findmnt wl-copy wl-paste pactl parec; do
                have_cmd "$dependency_command" || return 1
            done
            (have_cmd udisksctl || have_cmd umount) || return 1
            (have_cmd xclip || have_cmd xsel) || return 1
            ;;
    esac

    return 0
}

repository_help() {
    repo_family=$1
    repo_detail=${2-}

    printf '\n!! Package repository configuration problem detected.\n' >&2
    [ -z "$repo_detail" ] || printf '   %s\n' "$repo_detail" >&2

    case "$repo_family" in
        debian)
            printf '%s\n' \
                '   APT has no usable package sources.' \
                '   Review /etc/apt/sources.list and the .list/.sources files in' \
                '   /etc/apt/sources.list.d/.' \
                '   Ubuntu: open "Software & Updates" and enable the official Main repository.' \
                '   Debian: restore the official sources for the installed release.' \
                '   Then run: sudo apt update' >&2
            ;;
        arch)
            printf '%s\n' \
                '   One or more enabled pacman repositories have no active Server entry.' \
                '   EndeavourOS live session: open Welcome and run an' \
                '   "Update Mirrors (Arch, ...)" action (reflector-simple or rate-mirrors).' \
                '   Save the generated list; this repairs /etc/pacman.d/mirrorlist.' \
                '   If /etc/pacman.d/endeavouros-mirrorlist is also missing or empty, run:' \
                '     sudo touch /etc/pacman.d/endeavouros-mirrorlist' \
                '     eos-rankmirrors' \
                '   Then run: sudo pacman -Syu' >&2
            ;;
        fedora)
            printf '%s\n' \
                '   DNF has no enabled software repositories.' \
                '   List the configured repositories with: sudo dnf repolist --all' \
                '   Enable the official base and updates repositories in Software Repositories' \
                '   or with dnf config-manager, then run: sudo dnf makecache' >&2
            ;;
        alpine)
            printf '%s\n' \
                '   APK has no active repository entries in /etc/apk/repositories.' \
                '   Select an official mirror with: sudo setup-apkrepos' \
                '   Then run: sudo apk update' >&2
            ;;
        void)
            printf '%s\n' \
                '   XBPS has no usable package repository.' \
                '   Check the repository= entries in /etc/xbps.d and /usr/share/xbps.d.' \
                "   Select an official mirror with xmirror, or restore Void's main repository" \
                '   configuration for this architecture, then run: sudo xbps-install -S' >&2
            ;;
        suse)
            printf '%s\n' \
                '   Zypper has no enabled software repositories.' \
                '   List them with: sudo zypper repos --uri' \
                '   Enable the official repositories with YaST Software Repositories or:' \
                '     sudo zypper modifyrepo --enable <repository-alias>' \
                '   Then run: sudo zypper refresh' >&2
            ;;
        macos)
            printf '%s\n' \
                '   Homebrew cannot access its configured package source.' \
                '   Inspect the configuration with: brew config' \
                '   Repair Homebrew according to the reported remote/tap error, then run:' \
                '     brew update' >&2
            ;;
    esac

    printf '\n   After repairing the repositories, run ./install.sh again.\n' >&2
}

arch_partial_upgrade_help() {
    printf '%s\n' \
        '' \
        '!! Arch/Cachy package installation did not complete.' \
        '' \
        '   Scriptorium uses a full pacman -Syu transaction because Arch-based' \
        '   systems do not support partial upgrades. Resolve the conflict or' \
        '   stale mirror reported above, then complete the upgrade manually:' \
        '' \
        '     sudo pacman -Syu' \
        '' \
        '   After that completes, run ./install.sh again.' \
        '' >&2
}

package_unavailable_help() {
    unavailable_family=$1

    printf '%s\n' \
        '' \
        '!! A package required for the complete Scriptorium feature set is not available.' \
        '' >&2

    case "$unavailable_family" in
        debian)
            printf '%s\n' \
                '   On Ubuntu, make sure the Universe component is enabled.' \
                '   On Debian/Ubuntu releases that do not package WebKitGTK 4.1,' \
                '   upgrade to a current supported release before installing.' >&2
            ;;
        alpine)
            printf '%s\n' \
                '   Make sure both the main and community repositories for this' \
                '   Alpine release are enabled in /etc/apk/repositories.' >&2
            ;;
        arch)
            printf '%s\n' \
                '   Refresh mirrors and use repositories matching the installed' \
                '   Arch-derived distribution; do not mix release snapshots.' >&2
            ;;
        fedora | suse | void)
            printf '%s\n' \
                '   Make sure the official repositories for a currently supported' \
                '   release are enabled and match the installed system.' >&2
            ;;
        macos)
            printf '%s\n' \
                '   Run brew update and check that this macOS release is supported' \
                '   by the current Homebrew formulae.' >&2
            ;;
    esac

    printf '%s\n' \
        '' \
        '   Review the exact missing package in the package-manager output above,' \
        '   repair the repository/release configuration, then rerun ./install.sh.' \
        '' >&2
}

explain_repository_failure() {
    error_family=$1
    error_log=$2

    case "$error_family" in
        debian)
            if grep -Eqi \
                'unable to locate package|package .* has no installation candidate' \
                "$error_log"; then
                package_unavailable_help debian
                return 0
            fi
            if grep -Eqi \
                'list of sources could not be read|malformed entry .* (sources\.list|list file)|no active sources found' \
                "$error_log"; then
                repository_help debian
                return 0
            fi
            ;;
        arch)
            if grep -Eqi 'target not found:' "$error_log"; then
                package_unavailable_help arch
                return 0
            fi
            if grep -Eqi \
                'no servers configured for repository|no servers are configured for the repository' \
                "$error_log"; then
                repository_help arch
                return 0
            fi
            ;;
        fedora)
            if grep -Eqi 'no match for argument:|unable to find a match:' "$error_log"; then
                package_unavailable_help fedora
                return 0
            fi
            if grep -Eqi \
                'there are no enabled repositories|no enabled repositories|no repositories available' \
                "$error_log"; then
                repository_help fedora
                return 0
            fi
            ;;
        alpine)
            if grep -Eqi 'unable to select packages:|no such package' "$error_log"; then
                package_unavailable_help alpine
                return 0
            fi
            if grep -Eqi \
                'repositories file unavailable|no active repository entries' \
                "$error_log"; then
                repository_help alpine
                return 0
            fi
            ;;
        void)
            if grep -Eqi 'package .* not found|failed to find .* in repository' "$error_log"; then
                package_unavailable_help void
                return 0
            fi
            if grep -Eqi \
                'xbps-bin: no repositories|no repositories available|no usable package repository' \
                "$error_log"; then
                repository_help void
                return 0
            fi
            ;;
        suse)
            if grep -Eqi 'not found in package names|no provider of .* found' "$error_log"; then
                package_unavailable_help suse
                return 0
            fi
            if grep -Eqi \
                'there are no enabled repositories defined|no repositories defined|no enabled repositories' \
                "$error_log"; then
                repository_help suse
                return 0
            fi
            ;;
        macos)
            if grep -Eqi 'no available formula|no formulae or casks found' "$error_log"; then
                package_unavailable_help macos
                return 0
            fi
            if grep -Eqi \
                'invalid value for HOMEBREW_.*_GIT_REMOTE|not a git repository.*Homebrew|no remote.*origin' \
                "$error_log"; then
                repository_help macos
                return 0
            fi
            ;;
    esac

    return 1
}

run_package_command() {
    command_family=$1
    shift

    attempt=1
    while :; do
        cleanup_package_files
        package_log=$(mktemp "${TMPDIR:-/tmp}/scriptorium-packages.XXXXXX")
        package_status_file=$package_log.status
        : > "$package_status_file"

        # POSIX sh has no pipefail. Record the package manager's status separately
        # while tee keeps its output visible and available for diagnosis.
        (
            set +e
            "$@"
            command_status=$?
            printf '%s\n' "$command_status" > "$package_status_file"
            exit 0
        ) 2>&1 | tee "$package_log"

        command_status=
        IFS= read -r command_status < "$package_status_file" || command_status=1

        case "$command_status" in
            0)
                cleanup_package_files
                package_log=
                package_status_file=
                return 0
                ;;
            '' | *[!0-9]*)
                command_status=1
                ;;
        esac

        if [ "$attempt" -eq 1 ]; then
            printf '\n!! Package installation failed. This may be a temporary network or mirror hiccup.\n' >&2
            printf '!! Retrying once in 5 seconds...\n' >&2
            cleanup_package_files
            package_log=
            package_status_file=
            sleep 5
            attempt=2
            continue
        fi

        if ! explain_repository_failure "$command_family" "$package_log"; then
            if [ "$command_family" = arch ]; then
                arch_partial_upgrade_help
            else
                printf '\n!! Package installation failed; review the package-manager error above.\n' >&2
            fi
        fi

        cleanup_package_files
        package_log=
        package_status_file=
        return "$command_status"
    done
}

debian_sources_configured() {
    for source_file in /etc/apt/sources.list /etc/apt/sources.list.d/*.list; do
        [ -r "$source_file" ] || continue
        if awk '
            /^[[:space:]]*deb([[:space:]]+\[[^]]*\])?[[:space:]]+[^#[:space:]]+/ &&
            $0 !~ /^[[:space:]]*deb([[:space:]]+\[[^]]*\])?[[:space:]]+cdrom:/ {
                found=1
            }
            END { exit found ? 0 : 1 }
        ' "$source_file"; then
            return 0
        fi
    done

    for source_file in /etc/apt/sources.list.d/*.sources; do
        [ -r "$source_file" ] || continue
        if awk '
            BEGIN { RS=""; found=0 }
            {
                has_deb = $0 ~ /(^|\n)[[:space:]]*Types:[^\n]*(^|[[:space:]])deb([[:space:]]|$)/
                has_uri = $0 ~ /(^|\n)[[:space:]]*URIs:[[:space:]]*[^[:space:]#]/
                cdrom_only = $0 ~ /(^|\n)[[:space:]]*URIs:[[:space:]]*cdrom:/
                disabled = $0 ~ /(^|\n)[[:space:]]*Enabled:[[:space:]]*no([[:space:]]|$)/
                if (has_deb && has_uri && !cdrom_only && !disabled)
                    found=1
            }
            END { exit found ? 0 : 1 }
        ' "$source_file"; then
            return 0
        fi
    done

    return 1
}

check_repository_configuration() {
    check_family=$1

    case "$check_family" in
        debian)
            # apt-get expands this identifier; the shell must not.
            # shellcheck disable=SC2016
            if ! apt-get indextargets --no-release-info --format '$(IDENTIFIER)' \
                2>/dev/null | grep -q . && ! debian_sources_configured; then
                repository_help debian
                return 1
            fi
            ;;
        arch)
            if command -v pacman-conf >/dev/null 2>&1; then
                configured_repos=$(pacman-conf --repo-list 2>/dev/null) || return 0
                missing_repos=

                if [ -z "$configured_repos" ]; then
                    repository_help arch 'No pacman repositories are enabled.'
                    return 1
                fi

                while IFS= read -r repo_name; do
                    [ -n "$repo_name" ] || continue
                    repo_servers=$(pacman-conf --repo "$repo_name" Server 2>/dev/null) ||
                        repo_servers=
                    if [ -z "$repo_servers" ]; then
                        if [ -z "$missing_repos" ]; then
                            missing_repos=$repo_name
                        else
                            missing_repos="$missing_repos, $repo_name"
                        fi
                    fi
                done <<EOF
$configured_repos
EOF

                if [ -n "$missing_repos" ]; then
                    repository_help arch "Repositories without servers: $missing_repos"
                    return 1
                fi
            fi
            ;;
        alpine)
            if [ ! -r /etc/apk/repositories ] ||
                ! grep -Eq '^[[:space:]]*[^#[:space:]]' /etc/apk/repositories; then
                repository_help alpine
                return 1
            fi
            ;;
        void)
            active_xbps_repo=0
            for repo_file in /etc/xbps.d/*.conf /usr/share/xbps.d/*.conf; do
                [ -f "$repo_file" ] || continue
                if grep -Eq '^[[:space:]]*repository[[:space:]]*=' "$repo_file"; then
                    active_xbps_repo=1
                    break
                fi
            done
            if [ "$active_xbps_repo" -eq 0 ]; then
                repository_help void
                return 1
            fi
            ;;
    esac

    return 0
}

if [ "$family" = unknown ]; then
    family_file=$HOME/.config/simplesuite/family

    if [ -f "$family_file" ]; then
        saved_family=
        IFS= read -r saved_family < "$family_file" || true

        case "$saved_family" in
            debian | arch | fedora | alpine | void | suse)
                family=$saved_family
                ;;
            *)
                printf 'Invalid saved package family in %s\n' "$family_file" >&2
                exit 1
                ;;
        esac
    else
        printf '\nUnknown system detected.\n\n'
        while :; do
            printf '%s\n' \
                'Select package family:' \
                '1) debian (apt)' \
                '2) arch (pacman)' \
                '3) fedora (dnf)' \
                '4) alpine (apk)' \
                '5) void (xbps)' \
                '6) suse (zypper)'
            printf '\nEnter choice: '

            if ! IFS= read -r choice; then
                printf '\nUnable to read package family selection.\n' >&2
                exit 1
            fi

            case "$choice" in
                1) family=debian ;;
                2) family=arch ;;
                3) family=fedora ;;
                4) family=alpine ;;
                5) family=void ;;
                6) family=suse ;;
                *)
                    printf '\nInvalid choice. Enter a number from 1 to 6.\n\n' >&2
                    continue
                    ;;
            esac
            break
        done

        mkdir -p "$HOME/.config/simplesuite"
        printf '%s\n' "$family" > "$family_file"
        chmod 600 "$family_file"
    fi
fi

configure_homebrew_pkgconfig

if dependencies_already_present; then
    printf 'Package dependencies already present; skipping package manager install.\n'
    exit 0
fi

case "$distro_id" in
    rhel | centos | rocky | almalinux | ol | amzn)
        printf '%s\n' \
            'This RHEL-family release does not provide the complete Scriptorium' \
            'dependency set in its default official repositories.' \
            'Fedora is the supported DNF target. On this system, provision the' \
            'dependencies reported by scripts/checkdeps.sh (for example through' \
            'approved EPEL or vendor repositories), then rerun ./install.sh.' >&2
        exit 2
        ;;
    opensuse-leap | sles)
        printf '%s\n' \
            'This SUSE release does not provide the complete Scriptorium dependency' \
            'set in its default official repositories.' \
            'openSUSE Tumbleweed is the supported Zypper target. Provision every' \
            'dependency reported by scripts/checkdeps.sh, then rerun ./install.sh.' >&2
        exit 2
        ;;
esac

case "$family" in
    debian) package_manager=apt-get ;;
    arch) package_manager=pacman ;;
    fedora) package_manager=dnf ;;
    alpine) package_manager=apk ;;
    void) package_manager=xbps-install ;;
    suse) package_manager=zypper ;;
    macos) package_manager=brew ;;
    *) package_manager= ;;
esac

if [ -n "$package_manager" ] && ! have_cmd "$package_manager"; then
    printf 'Detected package family %s, but %s is not available on PATH.\n' \
        "$family" "$package_manager" >&2
    exit 1
fi

if [ "$family" != macos ] && [ "$(id -u)" -ne 0 ] && ! have_cmd sudo; then
    printf 'Package installation needs root privileges, but sudo is unavailable.\n' >&2
    printf 'Run ./install.sh as root or install/configure sudo first.\n' >&2
    exit 1
fi

case "$family" in
    debian)
        check_repository_configuration debian

        if command -v debconf-set-selections >/dev/null 2>&1; then
            {
                printf '%s\n' 'msmtp msmtp/apparmor boolean false'
                printf '%s\n' 'msmtp msmtp/apparmor seen true'
            } | as_root debconf-set-selections || true
        fi

        run_package_command debian as_root env DEBIAN_FRONTEND=noninteractive LC_ALL=C apt-get update
        run_package_command debian as_root env DEBIAN_FRONTEND=noninteractive LC_ALL=C apt-get install -y \
            build-essential pkg-config libncurses-dev libcurl4-openssl-dev libssl-dev libglib2.0-dev \
            git mpv poppler-utils pandoc \
            nano zip unzip tar xdg-utils file less fzf pulseaudio-utils libglib2.0-bin util-linux udisks2 wl-clipboard xclip xsel \
            python3 python3-gi gir1.2-gtk-3.0 gir1.2-webkit2-4.1 \
            isync msmtp calcurse links curl ca-certificates rsync cron
        ;;
    void)
        check_repository_configuration void
        run_package_command void as_root env LC_ALL=C xbps-install -Sy \
            base-devel pkg-config ncurses-devel glib-devel libcurl-devel openssl-devel \
            git mpv poppler-utils pandoc \
            nano zip unzip tar xdg-utils file less fzf pulseaudio-utils glib util-linux udisks2 wl-clipboard xclip xsel \
            python3 python3-gobject libwebkit2gtk41 \
            isync msmtp calcurse links curl ca-certificates rsync cronie
        ;;
    arch)
        check_repository_configuration arch
        arch_keyrings=archlinux-keyring
        for keyring in cachyos-keyring endeavouros-keyring manjaro-keyring; do
            if pacman -Qq "$keyring" >/dev/null 2>&1 ||
               pacman -Si "$keyring" >/dev/null 2>&1; then
                arch_keyrings="$arch_keyrings $keyring"
            fi
        done
        # Refresh keyrings first so a stale live image can authenticate the
        # immediately following full-system transaction.
        # shellcheck disable=SC2086
        run_package_command arch as_root env LC_ALL=C pacman -Sy --needed $arch_keyrings
        arch_jack_provider=pipewire-jack
        if pacman -Qq pipewire-jack >/dev/null 2>&1 || pacman -Qq jack2 >/dev/null 2>&1; then
            arch_jack_provider=
        fi
        run_package_command arch as_root env LC_ALL=C pacman -Syu --needed \
            base-devel pkgconf ncurses curl openssl \
            git mpv poppler pandoc-cli \
            nano zip unzip tar xdg-utils file less fzf libpulse $arch_jack_provider glib2 util-linux udisks2 wl-clipboard xclip xsel \
            python python-gobject webkit2gtk-4.1 \
            isync msmtp calcurse links ca-certificates rsync cronie
        ;;
    alpine)
        check_repository_configuration alpine
        run_package_command alpine as_root env LC_ALL=C apk add \
            build-base bash pkgconf ncurses-dev curl-dev openssl-dev \
            git mpv poppler-utils pandoc \
            nano zip unzip tar xdg-utils file less fzf pulseaudio-utils glib glib-dev util-linux udisks2 wl-clipboard xclip xsel \
            python3 py3-gobject3 webkit2gtk-4.1 \
            isync msmtp calcurse links curl ca-certificates rsync dcron
        ;;
    fedora)
        run_package_command fedora as_root env LC_ALL=C dnf install -y \
            gcc make pkgconf-pkg-config ncurses-devel libcurl-devel openssl-devel \
            git mpv poppler-utils pandoc \
            nano zip unzip tar xdg-utils file less fzf pulseaudio-utils glib2-devel util-linux udisks2 wl-clipboard xclip xsel \
            python3 python3-gobject webkit2gtk4.1 \
            isync msmtp calcurse links curl ca-certificates rsync cronie
        ;;
    suse)
        run_package_command suse as_root env LC_ALL=C zypper install -y \
            gcc make pkg-config ncurses-devel libcurl-devel libopenssl-devel \
            git mpv poppler-tools pandoc \
            nano zip unzip tar xdg-utils file less fzf pulseaudio-utils glib2-tools glib2-devel util-linux udisks2 wl-clipboard xclip xsel \
            python3 python3-gobject typelib-1_0-Gtk-3_0 typelib-1_0-WebKit2-4_1 \
            isync msmtp calcurse links curl ca-certificates rsync cron
        ;;
    macos)
        if ! command -v xcrun >/dev/null 2>&1 || ! xcrun --find clang >/dev/null 2>&1; then
            echo "Apple Command Line Tools are required. Run: xcode-select --install" >&2
            exit 1
        fi
        run_package_command macos env LC_ALL=C brew install \
            pkgconf ncurses curl make openssl@3 glib \
            git mpv poppler pandoc \
            nano zip unzip libmagic less fzf pulseaudio \
            isync msmtp calcurse links rsync
        ;;
    *)
        echo "Unknown platform family: $family" >&2
        echo "Install packages manually, then re-run ./install.sh" >&2
        exit 1
        ;;
esac

configure_homebrew_pkgconfig
if ! dependencies_already_present; then
    printf '\nPackage installation completed, but one or more expected dependencies are still unavailable.\n' >&2
    printf 'Dependency details follow; fix the reported package or PATH issue, then rerun ./install.sh.\n\n' >&2
    "$ROOT/scripts/checkdeps.sh" || true
    exit 1
fi

printf 'Package dependency installation verified.\n'
