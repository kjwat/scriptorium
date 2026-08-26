#!/bin/sh

# Shared platform detection for Scriptorium's website provisioner and verifier.

website_release_value() {
    wanted=$1
    release_file=${WEBSITE_OS_RELEASE:-/etc/os-release}

    [ -r "$release_file" ] || return 0
    awk -F= -v wanted="$wanted" '
        $1 == wanted {
            value = substr($0, index($0, "=") + 1)
            if (value ~ /^".*"$/ || value ~ /^'"'"'.*'"'"'$/)
                value = substr(value, 2, length(value) - 2)
            print value
            exit
        }
    ' "$release_file"
}

website_detect_family() {
    if [ -n "${WEBSITE_PLATFORM_FAMILY:-}" ]; then
        printf '%s\n' "$WEBSITE_PLATFORM_FAMILY"
        return
    fi

    host_os=${WEBSITE_HOST_OS:-$(uname -s 2>/dev/null || true)}
    case "$host_os" in
        Darwin) printf '%s\n' macos; return ;;
        FreeBSD) printf '%s\n' freebsd; return ;;
        Linux) ;;
        *) printf '%s\n' unsupported; return ;;
    esac

    distro_id=$(website_release_value ID)
    distro_like=$(website_release_value ID_LIKE)
    distro_words=" $distro_id $distro_like "
    case "$distro_words" in
        *" alpine "*) printf '%s\n' alpine ;;
        *" void "*) printf '%s\n' void ;;
        *" arch "*) printf '%s\n' arch ;;
        *" fedora "*|*" rhel "*) printf '%s\n' fedora ;;
        *" opensuse "*|*" suse "*) printf '%s\n' suse ;;
        *" debian "*|*" ubuntu "*) printf '%s\n' debian ;;
        *) printf '%s\n' unsupported ;;
    esac
}

website_detect_service_manager() {
    if [ -n "${WEBSITE_SERVICE_MANAGER:-}" ]; then
        printf '%s\n' "$WEBSITE_SERVICE_MANAGER"
        return
    fi

    host_os=${WEBSITE_HOST_OS:-$(uname -s 2>/dev/null || true)}
    case "$host_os" in
        Darwin) printf '%s\n' launchd ;;
        FreeBSD) printf '%s\n' freebsd ;;
        Linux)
            if command -v systemctl >/dev/null 2>&1 &&
               [ -d /run/systemd/system ]; then
                printf '%s\n' systemd
            elif command -v rc-service >/dev/null 2>&1 &&
                 command -v rc-update >/dev/null 2>&1; then
                printf '%s\n' openrc
            elif command -v sv >/dev/null 2>&1 && [ -d /etc/sv ]; then
                printf '%s\n' runit
            else
                printf '%s\n' unsupported
            fi
            ;;
        *) printf '%s\n' unsupported ;;
    esac
}
