#!/bin/sh
set -eu

SCRIPTORIUM_ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
REPO_URL="${SIMPLESUITE_REPO_URL:-https://github.com/kjwat/simplesuite.git}"
DEST="${SIMPLESUITE_DIR:-$HOME/simplesuite}"
SIMPLESUITE_SCRIPTS="${SIMPLESUITE_SCRIPTS:-simplebrowse-webkitd simplebrowse-jsdump simplesuite-uninstall}"
SIMPLESUITE_INSTALL_REMINDERS="${SIMPLESUITE_INSTALL_REMINDERS:-1}"
SIMPLESUITE_INSTALL_PACKAGES="${SIMPLESUITE_INSTALL_PACKAGES:-auto}"
SIMPLESUITE_INSTALL_FREEBSD_HELPER="${SIMPLESUITE_INSTALL_FREEBSD_HELPER:-auto}"
SIMPLESUITE_INSTALL_SIMPLESERVE_SYSTEM="${SIMPLESUITE_INSTALL_SIMPLESERVE_SYSTEM:-auto}"
FREEBSD_UNMOUNT_HELPER="${FREEBSD_UNMOUNT_HELPER:-/usr/local/libexec/simplefiles-freebsd-unmount}"
export SIMPLESUITE_INSTALL_FREEBSD_HELPER \
    SIMPLESUITE_INSTALL_SIMPLESERVE_SYSTEM FREEBSD_UNMOUNT_HELPER
SIMPLESUITE_BUILD_INSTALL_PACKAGES="$SIMPLESUITE_INSTALL_PACKAGES"
SIMPLESUITE_ASSETS="
simplecal-alarm.mp3
simplewords-typewriter.wav
simplewords-typewriter-alt.wav
simplewords-typewriter-space.wav
simplewords-typewriter-enter.wav
simplewords-typewriter-delete.wav
simplewords-typewriter-NOTICE.md
install-source
"
SIMPLESUITE_PROGRAMS="
simplebrowse
simplecal
simpleclock
simplefiles
simpleflac
simplegame
simplemail
simplenet
simplepdf
simplepod
simpleradio
simplenews
simplestats
simplever
simplevis
simplewords

"
SIMPLESUITE_HOST_OS="$(uname -s 2>/dev/null || echo unknown)"
case "$SIMPLESUITE_HOST_OS" in
    FreeBSD | Linux)
        SIMPLESUITE_PROGRAMS="$SIMPLESUITE_PROGRAMS
simpleserve
simpleserved
"
        ;;
esac

case "$SIMPLESUITE_INSTALL_REMINDERS" in
    0 | 1) ;;
    *)
        echo "SIMPLESUITE_INSTALL_REMINDERS must be 0 or 1." >&2
        exit 2
        ;;
esac

case "$SIMPLESUITE_INSTALL_PACKAGES" in
    0 | 1 | auto) ;;
    *)
        echo "SIMPLESUITE_INSTALL_PACKAGES must be 0, 1, or auto." >&2
        exit 2
        ;;
esac

case "$SIMPLESUITE_INSTALL_FREEBSD_HELPER" in
    auto | yes | true | 1 | require | skip | no | false | 0) ;;
    *)
        echo "SIMPLESUITE_INSTALL_FREEBSD_HELPER must be auto, require, or skip." >&2
        exit 2
        ;;
esac

case "$SIMPLESUITE_INSTALL_SIMPLESERVE_SYSTEM" in
    auto | yes | true | 1 | require | skip | no | false | 0) ;;
    *)
        echo "SIMPLESUITE_INSTALL_SIMPLESERVE_SYSTEM must be auto, require, or skip." >&2
        exit 2
        ;;
esac

trap 'exit 130' INT
trap 'exit 143' TERM

prepend_pkgconfig_dir() {
    pkgconfig_dir=$1
    [ -d "$pkgconfig_dir" ] || return 0

    case ":${PKG_CONFIG_PATH:-}:" in
        *":$pkgconfig_dir:"*) ;;
        *) PKG_CONFIG_PATH="$pkgconfig_dir${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}" ;;
    esac
}

configure_homebrew_build_environment() {
    [ "$(uname -s 2>/dev/null || echo unknown)" = Darwin ] || return 0

    if ! command -v brew >/dev/null 2>&1; then
        for brew_candidate in /opt/homebrew/bin/brew /usr/local/bin/brew; do
            [ -x "$brew_candidate" ] || continue
            PATH="${brew_candidate%/*}:$PATH"
            export PATH
            break
        done
    fi
    if ! command -v brew >/dev/null 2>&1; then
        echo "Homebrew is required to build SimpleSuite on macOS." >&2
        exit 1
    fi

    # Keg-only formula metadata is not necessarily on the default search path.
    for formula in ncurses glib curl openssl@3; do
        formula_prefix=$(brew --prefix "$formula" 2>/dev/null) || {
            echo "Required Homebrew formula is not installed: $formula" >&2
            exit 1
        }
        for pkgconfig_dir in "$formula_prefix/lib/pkgconfig" \
                             "$formula_prefix/share/pkgconfig"; do
            prepend_pkgconfig_dir "$pkgconfig_dir"
        done
    done
    export PKG_CONFIG_PATH
}

directory_has_entries() {
    [ -d "$1" ] || return 1

    for entry in "$1"/.[!.]* "$1"/..?* "$1"/*; do
        [ -e "$entry" ] || [ -L "$entry" ] || continue
        return 0
    done

    return 1
}

run_checkdeps() {
    checkdeps_script=$1

    [ -x "$checkdeps_script" ] || return 0
    if head -n 1 "$checkdeps_script" 2>/dev/null | grep -q 'bash' &&
       ! command -v bash >/dev/null 2>&1; then
        echo "Skipping $checkdeps_script because Bash is not on PATH." >&2
        echo "SimpleSuite build errors, if any, will still be reported below." >&2
        return 0
    fi

    if ! "$checkdeps_script"; then
        echo "Dependency check reported missing packages; continuing with the build." >&2
        echo "Install the reported packages for the complete runtime feature set." >&2
    fi
}

install_packages_if_needed() {
    case "$SIMPLESUITE_INSTALL_PACKAGES" in
        0)
            return 0
            ;;
        auto)
            case "$(uname -s 2>/dev/null || true)" in
                Darwin|FreeBSD) ;;
                *) return 0 ;;
            esac
            ;;
    esac

    if [ ! -x "$SCRIPTORIUM_ROOT/scripts/install-packages.sh" ]; then
        if [ "$SIMPLESUITE_INSTALL_PACKAGES" = 1 ]; then
            echo "SIMPLESUITE_INSTALL_PACKAGES=1, but scripts/install-packages.sh was not found." >&2
            exit 1
        fi
        return 0
    fi

    "$SCRIPTORIUM_ROOT/scripts/install-packages.sh"
    SIMPLESUITE_BUILD_INSTALL_PACKAGES=0
}

install_packages_if_needed

if ! command -v git >/dev/null 2>&1; then
    echo "git is required to install SimpleSuite." >&2
    exit 1
fi

mkdir -p "$(dirname "$DEST")"

if [ -e "$DEST/.git" ]; then
    echo "SimpleSuite already cloned at $DEST"
    if ! git -C "$DEST" pull --ff-only; then
        echo "Failed to update SimpleSuite at $DEST with git pull --ff-only." >&2
        echo "Resolve the checkout state, then rerun the Scriptorium installer." >&2
        exit 1
    fi
else
    if [ -d "$DEST" ] && directory_has_entries "$DEST"; then
        echo "SimpleSuite destination exists and is not a Git checkout: $DEST" >&2
        echo "Move it aside or set SIMPLESUITE_DIR to a different path." >&2
        exit 1
    fi
    git clone "$REPO_URL" "$DEST"
fi

configure_homebrew_build_environment

case "$SIMPLESUITE_HOST_OS" in
    Darwin|FreeBSD)
        MAKE=${MAKE:-gmake}
        export MAKE
        ;;
esac

if [ -x "$SCRIPTORIUM_ROOT/scripts/checkdeps.sh" ]; then
    run_checkdeps "$SCRIPTORIUM_ROOT/scripts/checkdeps.sh"
elif [ -x "$DEST/checkdeps.sh" ]; then
    run_checkdeps "$DEST/checkdeps.sh"
fi

if [ -x "$DEST/build.sh" ]; then
    (cd "$DEST" && \
        SIMPLESUITE_INSTALL_PACKAGES="$SIMPLESUITE_BUILD_INSTALL_PACKAGES" \
        SIMPLESUITE_INSTALL_SIMPLESERVE_SYSTEM="$SIMPLESUITE_INSTALL_SIMPLESERVE_SYSTEM" \
        ./build.sh)
elif [ -f "$DEST/Makefile" ]; then
    make_cmd=${MAKE:-make}
    (cd "$DEST" && "$make_cmd" install)
else
    echo "No build.sh or Makefile found in $DEST" >&2
    exit 1
fi

echo "Verifying SimpleSuite binaries in $HOME/.local/bin"
missing=0
for program in $SIMPLESUITE_PROGRAMS; do
    if [ -x "$HOME/.local/bin/$program" ]; then
        printf '  ok: %s\n' "$program"
    else
        printf '  missing: %s\n' "$HOME/.local/bin/$program" >&2
        missing=1
    fi
done

if [ "$missing" -ne 0 ]; then
    echo "SimpleSuite build/install did not produce every expected binary." >&2
    exit 1
fi

if [ -n "$SIMPLESUITE_SCRIPTS" ]; then
    echo "Verifying SimpleSuite helper scripts in $HOME/.local/bin"
    for program in $SIMPLESUITE_SCRIPTS; do
        if [ -x "$HOME/.local/bin/$program" ]; then
            printf '  ok: %s\n' "$program"
        else
            printf '  missing: %s\n' "$HOME/.local/bin/$program" >&2
            missing=1
        fi
    done

    if [ "$missing" -ne 0 ]; then
        echo "SimpleSuite build/install did not produce every expected helper script." >&2
        exit 1
    fi
fi

echo "Verifying SimpleSuite shared assets in $HOME/.local/share/simplesuite"
for asset in $SIMPLESUITE_ASSETS; do
    if [ -r "$HOME/.local/share/simplesuite/$asset" ]; then
        printf '  ok: %s\n' "$asset"
    else
        printf '  missing: %s\n' \
            "$HOME/.local/share/simplesuite/$asset" >&2
        missing=1
    fi
done

if [ ! -f "$HOME/.config/simplewords/config" ]; then
    printf '  missing: %s\n' "$HOME/.config/simplewords/config" >&2
    missing=1
fi

if [ "$missing" -ne 0 ]; then
    echo "SimpleSuite install did not produce its complete runtime payload." >&2
    exit 1
fi

config_home=${XDG_CONFIG_HOME:-$HOME/.config}
echo "Verifying SimpleSuite config payload"
for config_file in \
    "$config_home/simplenews/config.example" \
    "$config_home/simplenews/urls.example" \
    "$config_home/simplemail/config" \
    "$HOME/.config/simplefiles/config" \
    "$HOME/.config/simplewords/config"; do
    if [ -r "$config_file" ]; then
        printf '  ok: %s\n' "$config_file"
    else
        printf '  missing: %s\n' "$config_file" >&2
        missing=1
    fi
done

if [ "$(uname -s 2>/dev/null || true)" = FreeBSD ]; then
    case "$SIMPLESUITE_INSTALL_FREEBSD_HELPER" in
        skip | no | false | 0) ;;
        *)
            if [ -x "$FREEBSD_UNMOUNT_HELPER" ]; then
                printf '  ok: %s\n' "$FREEBSD_UNMOUNT_HELPER"
            elif [ "$SIMPLESUITE_INSTALL_FREEBSD_HELPER" = require ]; then
                printf '  missing: %s\n' "$FREEBSD_UNMOUNT_HELPER" >&2
                missing=1
            else
                printf '  skipped: %s (run an interactive install or use require mode)\n' \
                    "$FREEBSD_UNMOUNT_HELPER"
            fi
            ;;
    esac
fi

case "$SIMPLESUITE_HOST_OS:$SIMPLESUITE_INSTALL_SIMPLESERVE_SYSTEM" in
    FreeBSD:skip|FreeBSD:no|FreeBSD:false|FreeBSD:0|Linux:skip|Linux:no|Linux:false|Linux:0) ;;
    FreeBSD:*|Linux:*)
        if [ -x "$DEST/verify-simpleserve-system.sh" ] &&
           "$DEST/verify-simpleserve-system.sh" \
               "$HOME/.local/bin/simpleserved" >/dev/null 2>&1; then
            printf '  ok: %s\n' /usr/local/sbin/simpleserved
        elif [ "$SIMPLESUITE_INSTALL_SIMPLESERVE_SYSTEM" = require ]; then
            echo "SimpleServe system service is missing, stale, or stopped." >&2
            missing=1
        else
            echo "  skipped: SimpleServe system service (run an interactive install or use require mode)"
        fi
        ;;
esac

if [ "$missing" -ne 0 ]; then
    echo "SimpleSuite install did not produce its complete config/helper payload." >&2
    exit 1
fi

if [ "$SIMPLESUITE_INSTALL_REMINDERS" -eq 1 ]; then
    if [ -x "$HOME/.local/bin/simplecal" ]; then
        "$HOME/.local/bin/simplecal" --install-reminders || echo "Warning: SimpleCal reminder setup failed; run simplecal --install-reminders later." >&2
    elif command -v simplecal >/dev/null 2>&1; then
        simplecal --install-reminders || echo "Warning: SimpleCal reminder setup failed; run simplecal --install-reminders later." >&2
    fi
fi
