#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
family="$("$ROOT/scripts/detect-platform.sh")"
package_log=
package_status_file=

cleanup_package_files() {
    [ -z "$package_log" ] || rm -f -- "$package_log"
    [ -z "$package_status_file" ] || rm -f -- "$package_status_file"
}

trap cleanup_package_files EXIT

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
        '!! Arch/Cachy package state appears to be stale.' \
        '' \
        '   Scriptorium does not run a full system upgrade for you,' \
        '   because that would be a surprise distro upgrade during setup.' \
        '' \
        '   Arch-based systems do not support partial upgrades. If pacman' \
        '   reports dependency conflicts, missing package files, or library' \
        '   version mismatches, update the system first:' \
        '' \
        '     sudo pacman -Syu' \
        '' \
        '   After that completes, run ./install.sh again.' \
        '' >&2
}

explain_repository_failure() {
    error_family=$1
    error_log=$2

    case "$error_family" in
        debian)
            if grep -Eqi \
                'list of sources could not be read|malformed entry .* (sources\.list|list file)|no active sources found' \
                "$error_log"; then
                repository_help debian
                return 0
            fi
            ;;
        arch)
            if grep -Eqi \
                'no servers configured for repository|no servers are configured for the repository' \
                "$error_log"; then
                repository_help arch
                return 0
            fi
            ;;
        fedora)
            if grep -Eqi \
                'there are no enabled repositories|no enabled repositories|no repositories available' \
                "$error_log"; then
                repository_help fedora
                return 0
            fi
            ;;
        alpine)
            if grep -Eqi \
                'repositories file unavailable|no active repository entries' \
                "$error_log"; then
                repository_help alpine
                return 0
            fi
            ;;
        void)
            if grep -Eqi \
                'xbps-bin: no repositories|no repositories available|no usable package repository' \
                "$error_log"; then
                repository_help void
                return 0
            fi
            ;;
        suse)
            if grep -Eqi \
                'there are no enabled repositories defined|no repositories defined|no enabled repositories' \
                "$error_log"; then
                repository_help suse
                return 0
            fi
            ;;
        macos)
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

check_repository_configuration() {
    check_family=$1

    case "$check_family" in
        debian)
            if ! apt-get indextargets --no-release-info --format '$(IDENTIFIER)' \
                2>/dev/null | grep -q .; then
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

case "$family" in
    debian)
        check_repository_configuration debian

        if command -v debconf-set-selections >/dev/null 2>&1; then
            {
                printf '%s\n' 'msmtp msmtp/apparmor boolean false'
                printf '%s\n' 'msmtp msmtp/apparmor seen true'
            } | sudo debconf-set-selections || true
        fi

        run_package_command debian sudo env DEBIAN_FRONTEND=noninteractive LC_ALL=C apt update
        run_package_command debian sudo env DEBIAN_FRONTEND=noninteractive LC_ALL=C apt install -y \
            build-essential pkg-config libncursesw5-dev libcurl4-openssl-dev libssl-dev \
            git mpv poppler-utils pandoc \
            nano zip unzip xdg-utils file less fzf pulseaudio-utils libglib2.0-bin wl-clipboard xclip xsel \
            python3 python3-gi gir1.2-gtk-3.0 gir1.2-webkit2-4.1 \
            isync msmtp calcurse links curl ca-certificates rsync
        ;;
    void)
        check_repository_configuration void
        run_package_command void sudo env LC_ALL=C xbps-install -Sy \
            base-devel pkg-config ncurses-devel libcurl-devel openssl-devel \
            git mpv poppler-utils pandoc \
            nano zip unzip xdg-utils file less fzf pulseaudio-utils glib wl-clipboard xclip xsel \
            python3 python3-gobject webkit2gtk \
            isync msmtp calcurse links curl ca-certificates rsync
        ;;
    arch)
        check_repository_configuration arch
        if pacman -Si cachyos-keyring >/dev/null 2>&1; then
            run_package_command arch sudo env LC_ALL=C pacman -Sy --needed archlinux-keyring cachyos-keyring openssl
        else
            run_package_command arch sudo env LC_ALL=C pacman -Sy --needed archlinux-keyring openssl
        fi
        run_package_command arch sudo env LC_ALL=C pacman -S --needed \
            base-devel pkgconf ncurses curl openssl \
            git mpv poppler pandoc-cli \
            nano zip unzip xdg-utils file less fzf libpulse pipewire-jack glib2 wl-clipboard xclip xsel \
            python python-gobject webkit2gtk-4.1 \
            isync msmtp calcurse links ca-certificates rsync
        ;;
    alpine)
        check_repository_configuration alpine
        run_package_command alpine sudo env LC_ALL=C apk add \
            build-base pkgconf ncurses-dev curl-dev openssl-dev \
            git mpv poppler-utils pandoc \
            nano zip unzip xdg-utils file less fzf pulseaudio-utils glib wl-clipboard xclip xsel \
            python3 py3-gobject3 webkit2gtk-4.1 \
            isync msmtp calcurse links ca-certificates rsync
        ;;
    fedora)
        run_package_command fedora sudo env LC_ALL=C dnf install -y \
            gcc make pkgconf-pkg-config ncurses-devel libcurl-devel openssl-devel \
            git mpv poppler-utils pandoc \
            nano zip unzip xdg-utils file less fzf pulseaudio-utils glib2 wl-clipboard xclip xsel \
            python3 python3-gobject webkit2gtk4.1 \
            isync msmtp calcurse links curl ca-certificates rsync
        ;;
    suse)
        run_package_command suse sudo env LC_ALL=C zypper install -y \
            gcc make pkg-config ncurses-devel libcurl-devel libopenssl-devel \
            git mpv poppler-tools pandoc \
            nano zip unzip xdg-utils file less fzf pulseaudio-utils glib2-tools wl-clipboard xclip xsel \
            python3 python3-gobject typelib-1_0-Gtk-3_0 typelib-1_0-WebKit2-4_1 \
            isync msmtp calcurse links curl ca-certificates rsync
        ;;
    macos)
        run_package_command macos env LC_ALL=C brew install \
            pkg-config ncurses curl make openssl@3 \
            git mpv poppler pandoc \
            nano zip unzip file less fzf \
            python3 pygobject3 gtk+3 webkitgtk \
            isync msmtp calcurse links rsync
        ;;
    *)
        echo "Unknown platform family: $family" >&2
        echo "Install packages manually, then re-run ./install.sh" >&2
        exit 1
        ;;
esac
