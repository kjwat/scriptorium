#!/bin/sh
set -eu

SCRIPTORIUM_ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
REPO_URL="${SIMPLESUITE_REPO_URL:-https://github.com/kjwat/simplesuite.git}"
DEST="${SIMPLESUITE_DIR:-$HOME/simplesuite}"
SIMPLESUITE_SCRIPTS="${SIMPLESUITE_SCRIPTS:-simplebrowse-webkitd simplebrowse-jsdump simplesuite-uninstall}"
SIMPLESUITE_INSTALL_REMINDERS="${SIMPLESUITE_INSTALL_REMINDERS:-1}"
SIMPLESUITE_INSTALL_PACKAGES="${SIMPLESUITE_INSTALL_PACKAGES:-auto}"
SIMPLESUITE_PROGRAM_FILTER="${SIMPLESUITE_PROGRAM_FILTER:-}"
SIMPLESUITE_LINK_BUILD_OUTPUTS="${SIMPLESUITE_LINK_BUILD_OUTPUTS:-1}"
. "$SCRIPTORIUM_ROOT/scripts/resolve-simpleserve-role.sh"
SIMPLESUITE_NETWORK_ROLE=$(scriptorium_resolve_simpleserve_role) || exit $?
case "$SIMPLESUITE_NETWORK_ROLE" in
    none) SIMPLESUITE_INSTALL_SIMPLESERVE=0 ;;
    client | server) SIMPLESUITE_INSTALL_SIMPLESERVE=1 ;;
esac
SIMPLESUITE_INSTALL_FREEBSD_HELPER="${SIMPLESUITE_INSTALL_FREEBSD_HELPER:-auto}"
SIMPLESUITE_INSTALL_SIMPLESERVE_SYSTEM="${SIMPLESUITE_INSTALL_SIMPLESERVE_SYSTEM:-auto}"
FREEBSD_UNMOUNT_HELPER="${FREEBSD_UNMOUNT_HELPER:-/usr/local/libexec/simplefiles-freebsd-unmount}"
export SIMPLESUITE_INSTALL_SIMPLESERVE SIMPLESUITE_NETWORK_ROLE \
    SIMPLESUITE_INSTALL_FREEBSD_HELPER \
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
install-manifest
command-abbreviations
"
SIMPLESUITE_PROGRAMS="
simplebrowse
simplecal
simpleclock
simplefiles
simpleflac
simplegame
simplemail
simplepdf
simplepod
simpleradio
simplenews
simplestats
simplever
simplevis
simplewords

"
SIMPLESUITE_COMMAND_ALIASES="
browse:simplebrowse
cal:simplecal
clock:simpleclock
files:simplefiles
flac:simpleflac
game:simplegame
mail:simplemail
news:simplenews
pdf:simplepdf
pod:simplepod
radio:simpleradio
stats:simplestats
suite-uninstall:simplesuite-uninstall
ver:simplever
vis:simplevis
words:simplewords
"
SIMPLESUITE_HOST_OS="$(uname -s 2>/dev/null || echo unknown)"

case "$SIMPLESUITE_INSTALL_SIMPLESERVE" in
    0 | 1) ;;
    *)
        echo "SIMPLESUITE_INSTALL_SIMPLESERVE must be 0 or 1." >&2
        exit 2
        ;;
esac

case "$SIMPLESUITE_HOST_OS" in
    Linux)
        SIMPLESUITE_PROGRAMS="$SIMPLESUITE_PROGRAMS
simplenet
simpleblue
"
        SIMPLESUITE_COMMAND_ALIASES="$SIMPLESUITE_COMMAND_ALIASES
net:simplenet
blue:simpleblue
"
        ;;
    FreeBSD)
        SIMPLESUITE_PROGRAMS="$SIMPLESUITE_PROGRAMS
simplenet
"
        SIMPLESUITE_COMMAND_ALIASES="$SIMPLESUITE_COMMAND_ALIASES
net:simplenet
"
        ;;
    Darwin) ;;
esac

case "$SIMPLESUITE_HOST_OS" in
    Darwin | FreeBSD | Linux)
        if [ "$SIMPLESUITE_INSTALL_SIMPLESERVE" -eq 1 ]; then
        SIMPLESUITE_PROGRAMS="$SIMPLESUITE_PROGRAMS
simpleserve
simpleserved
"
        SIMPLESUITE_COMMAND_ALIASES="$SIMPLESUITE_COMMAND_ALIASES
serve:simpleserve
"
        fi
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

case "$SIMPLESUITE_LINK_BUILD_OUTPUTS" in
    0 | 1) ;;
    *)
        echo "SIMPLESUITE_LINK_BUILD_OUTPUTS must be 0 or 1." >&2
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

SIMPLESUITE_RESOLVED_SHA=$(git -C "$DEST" rev-parse --verify HEAD^{commit}) || {
    echo "Could not resolve the fetched SimpleSuite commit." >&2
    exit 1
}
if [ -n "$(git -C "$DEST" status --porcelain --untracked-files=normal)" ]; then
    echo "SimpleSuite release checkout is dirty after update: $DEST" >&2
    echo "Review or remove local changes before building an installable image." >&2
    exit 1
fi
export SIMPLESUITE_RESOLVED_SHA

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

if [ -n "$SIMPLESUITE_PROGRAM_FILTER" ]; then
    make_cmd=${MAKE:-make}
    for program in $SIMPLESUITE_PROGRAM_FILTER; do
        listed=0
        for allowed_program in $SIMPLESUITE_PROGRAMS $SIMPLESUITE_SCRIPTS; do
            if [ "$allowed_program" = "$program" ]; then
                listed=1
                break
            fi
        done
        if [ "$listed" -ne 1 ]; then
            echo "Refusing program outside the SimpleSuite master list: $program" >&2
            exit 2
        fi
        case $program in
            simplesuite-uninstall)
                install -m 0755 "$DEST/uninstall.sh" \
                    "$HOME/.local/bin/simplesuite-uninstall"
                ;;
            simplebrowse-webkitd | simplebrowse-jsdump)
                install -m 0755 "$DEST/$program" "$HOME/.local/bin/$program"
                ;;
            *)
                (cd "$DEST" && "$make_cmd" \
                    SIMPLESUITE_SOURCE_SHA="$SIMPLESUITE_RESOLVED_SHA" \
                    "$program")
                install -m 0755 "$DEST/build/$program" \
                    "$HOME/.local/bin/$program"
                ;;
        esac
    done
elif [ -x "$DEST/build.sh" ]; then
    (cd "$DEST" && \
        SIMPLESUITE_INSTALL_PACKAGES="$SIMPLESUITE_BUILD_INSTALL_PACKAGES" \
        SIMPLESUITE_INSTALL_SIMPLESERVE="$SIMPLESUITE_INSTALL_SIMPLESERVE" \
        SIMPLESUITE_NETWORK_ROLE="$SIMPLESUITE_NETWORK_ROLE" \
        SIMPLESUITE_INSTALL_SIMPLESERVE_SYSTEM="$SIMPLESUITE_INSTALL_SIMPLESERVE_SYSTEM" \
        SIMPLESUITE_SOURCE_SHA="$SIMPLESUITE_RESOLVED_SHA" \
        SIMPLESUITE_REQUIRE_CLEAN=1 \
        ./build.sh)
elif [ -f "$DEST/Makefile" ]; then
    make_cmd=${MAKE:-make}
    (cd "$DEST" && "$make_cmd" \
        SIMPLESUITE_SOURCE_SHA="$SIMPLESUITE_RESOLVED_SHA" \
        SIMPLESUITE_REQUIRE_CLEAN=1 release-simplewords && \
        "$make_cmd" \
        SIMPLESUITE_SOURCE_SHA="$SIMPLESUITE_RESOLVED_SHA" \
        SIMPLESUITE_REQUIRE_CLEAN=1 install)
else
    echo "No build.sh or Makefile found in $DEST" >&2
    exit 1
fi

if [ "$SIMPLESUITE_LINK_BUILD_OUTPUTS" -eq 1 ]; then
    echo "Linking canonical SimpleSuite commands to $DEST/build"
    mkdir -p "$HOME/.local/bin"
    linked_programs=$SIMPLESUITE_PROGRAMS
    if [ -n "$SIMPLESUITE_PROGRAM_FILTER" ]; then
        linked_programs=$SIMPLESUITE_PROGRAM_FILTER
    fi
    for program in $linked_programs; do
        case $program in
            simplesuite-uninstall | simplebrowse-webkitd | simplebrowse-jsdump)
                continue
                ;;
        esac
        build_output=$DEST/build/$program
        link_path=$HOME/.local/bin/$program
        link_tmp=$HOME/.local/bin/.$program.link.$$
        if [ ! -x "$build_output" ]; then
            echo "Missing SimpleSuite build output: $build_output" >&2
            exit 1
        fi
        rm -f "$link_tmp"
        ln -s "$build_output" "$link_tmp"
        mv -f "$link_tmp" "$link_path"
        printf '  linked: %s -> %s\n' "$link_path" "$build_output"
    done
fi

if [ -n "$SIMPLESUITE_PROGRAM_FILTER" ]; then
    for program in $SIMPLESUITE_PROGRAM_FILTER; do
        if [ ! -x "$HOME/.local/bin/$program" ]; then
            echo "Missing filtered SimpleSuite install: $program" >&2
            exit 1
        fi
        printf '  installed missing program: %s\n' "$program"
    done
    for alias_mapping in $SIMPLESUITE_COMMAND_ALIASES; do
        short_command=${alias_mapping%%:*}
        full_command=${alias_mapping#*:}
        alias_path=$HOME/.local/bin/$short_command
        if [ -L "$alias_path" ] &&
           [ "$(readlink "$alias_path")" = "$full_command" ]; then
            rm -f "$alias_path"
        fi
    done
    exit 0
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

echo "Removing legacy SimpleSuite short-command symlinks"
for alias_mapping in $SIMPLESUITE_COMMAND_ALIASES; do
    short_command=${alias_mapping%%:*}
    full_command=${alias_mapping#*:}
    alias_path=$HOME/.local/bin/$short_command
    if [ -L "$alias_path" ] &&
       [ "$(readlink "$alias_path")" = "$full_command" ]; then
        rm -f "$alias_path"
        printf '  removed: %s (shell alias targets %s)\n' \
            "$short_command" "$full_command"
    fi
done

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

expected_simplewords_version="simplewords $SIMPLESUITE_RESOLVED_SHA"
actual_simplewords_version=$(
    "$HOME/.local/bin/simplewords" --version 2>/dev/null || true
)
if [ "$actual_simplewords_version" = "$expected_simplewords_version" ]; then
    printf '  ok: SimpleWords source revision %s\n' "$SIMPLESUITE_RESOLVED_SHA"
else
    printf '  stale: SimpleWords version is %s (expected %s)\n' \
        "${actual_simplewords_version:-unavailable}" \
        "$expected_simplewords_version" >&2
    missing=1
fi

install_manifest=$HOME/.local/share/simplesuite/install-manifest
if grep -qx "simplesuite_source_sha=$SIMPLESUITE_RESOLVED_SHA" \
        "$install_manifest" 2>/dev/null &&
   grep -qx "simplewords_build_revision=$SIMPLESUITE_RESOLVED_SHA" \
        "$install_manifest" 2>/dev/null; then
    printf '  ok: %s records %s\n' "$install_manifest" \
        "$SIMPLESUITE_RESOLVED_SHA"
else
    printf '  stale: %s does not record fetched SHA %s\n' \
        "$install_manifest" "$SIMPLESUITE_RESOLVED_SHA" >&2
    missing=1
fi

if [ "$missing" -ne 0 ]; then
    echo "SimpleSuite revision provenance verification failed." >&2
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

case "$SIMPLESUITE_HOST_OS:$SIMPLESUITE_INSTALL_SIMPLESERVE:$SIMPLESUITE_INSTALL_SIMPLESERVE_SYSTEM" in
    Darwin:0:*|FreeBSD:0:*|Linux:0:*) ;;
    Darwin:1:skip|Darwin:1:no|Darwin:1:false|Darwin:1:0|FreeBSD:1:skip|FreeBSD:1:no|FreeBSD:1:false|FreeBSD:1:0|Linux:1:skip|Linux:1:no|Linux:1:false|Linux:1:0) ;;
    Darwin:1:*|FreeBSD:1:*|Linux:1:*)
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
