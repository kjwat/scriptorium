#!/bin/sh
set -eu

SCRIPTORIUM_ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
REPO_URL="${SIMPLESUITE_REPO_URL:-https://github.com/kjwat/simplesuite.git}"
DEST="${SIMPLESUITE_DIR:-$HOME/simplesuite}"
SIMPLESUITE_SCRIPTS="${SIMPLESUITE_SCRIPTS:-simplebrowse-webkitd simplebrowse-jsdump simplesuite-uninstall}"
SIMPLESUITE_INSTALL_REMINDERS="${SIMPLESUITE_INSTALL_REMINDERS:-1}"
SIMPLESUITE_INSTALL_PACKAGES="${SIMPLESUITE_INSTALL_PACKAGES:-auto}"
SIMPLESUITE_PROGRAM_FILTER="${SIMPLESUITE_PROGRAM_FILTER:-}"
SYSTEM_BIN_DIR="${SIMPLESUITE_SYSTEM_BIN_DIR:-/usr/local/bin}"
SYSTEM_DAEMON="${SIMPLESERVE_DAEMON_BINARY:-/usr/local/sbin/simpleserved}"
. "$SCRIPTORIUM_ROOT/scripts/resolve-simpleserve-role.sh"
. "$SCRIPTORIUM_ROOT/scripts/bounded-command.sh"
SIMPLESUITE_NETWORK_ROLE=$(scriptorium_resolve_simpleserve_role) || exit $?
case "$SIMPLESUITE_NETWORK_ROLE" in
    none) SIMPLESUITE_INSTALL_SIMPLESERVE=0 ;;
    client | server) SIMPLESUITE_INSTALL_SIMPLESERVE=1 ;;
esac
SIMPLESUITE_INSTALL_FREEBSD_HELPER="${SIMPLESUITE_INSTALL_FREEBSD_HELPER:-auto}"
SIMPLESUITE_INSTALL_SIMPLESERVE_SYSTEM="${SIMPLESUITE_INSTALL_SIMPLESERVE_SYSTEM:-preserve}"
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
program-manifest.sh
"
SIMPLESUITE_PROGRAMS=
SIMPLESUITE_COMMAND_ALIASES=
SIMPLESUITE_HOST_OS="$(uname -s 2>/dev/null || echo unknown)"

case "$SIMPLESUITE_INSTALL_SIMPLESERVE" in
    0 | 1) ;;
    *)
        echo "SIMPLESUITE_INSTALL_SIMPLESERVE must be 0 or 1." >&2
        exit 2
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
    preserve | auto | yes | true | 1 | require | skip | no | false | 0) ;;
    *)
        echo "SIMPLESUITE_INSTALL_SIMPLESERVE_SYSTEM must be preserve, auto, require, or skip." >&2
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
    if scriptorium_bounded 10 env GIT_TERMINAL_PROMPT=0 \
        GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes -o ConnectTimeout=5 -o ConnectionAttempts=1}" \
        git -C "$DEST" -c http.lowSpeedLimit=1 -c http.lowSpeedTime=5 fetch; then
        if ! git -C "$DEST" merge --ff-only '@{upstream}'; then
            echo "Cannot fast-forward SimpleSuite at $DEST; resolve the checkout state." >&2
            exit 1
        fi
    else
        echo "SimpleSuite update unavailable; building the existing local checkout."
    fi
else
    if [ -d "$DEST" ] && directory_has_entries "$DEST"; then
        echo "SimpleSuite destination exists and is not a Git checkout: $DEST" >&2
        echo "Move it aside or set SIMPLESUITE_DIR to a different path." >&2
        exit 1
    fi
    scriptorium_bounded 60 env GIT_TERMINAL_PROMPT=0 \
        GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes -o ConnectTimeout=5 -o ConnectionAttempts=1}" \
        git -c http.lowSpeedLimit=1 -c http.lowSpeedTime=5 clone "$REPO_URL" "$DEST" || {
        echo "SimpleSuite source is not cached at $DEST; a first clone needs connectivity." >&2
        exit 1
    }
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
if [ ! -r "$DEST/program-manifest.sh" ]; then
    echo "SimpleSuite checkout has no program manifest: $DEST/program-manifest.sh" >&2
    exit 1
fi
. "$DEST/program-manifest.sh"
SIMPLESUITE_PROGRAMS=$(simplesuite_programs "$SIMPLESUITE_HOST_OS" \
    "$SIMPLESUITE_INSTALL_SIMPLESERVE")
SIMPLESUITE_COMMAND_ALIASES=$(simplesuite_program_aliases \
    "$SIMPLESUITE_HOST_OS" "$SIMPLESUITE_INSTALL_SIMPLESERVE")
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
            simplesuite-uninstall | simplebrowse-webkitd | simplebrowse-jsdump)
                ;;
            simpleserved)
                echo "Preserving installed simpleserved; it is not updated by Scriptorium."
                ;;
            *)
                (cd "$DEST" && "$make_cmd" \
                    SIMPLESUITE_SOURCE_SHA="$SIMPLESUITE_RESOLVED_SHA" \
                    "$program")
                ;;
        esac
    done
elif [ -x "$DEST/build.sh" ]; then
    (cd "$DEST" && \
        SIMPLESUITE_INSTALL_PACKAGES="$SIMPLESUITE_BUILD_INSTALL_PACKAGES" \
        SIMPLESUITE_INSTALL_SIMPLESERVE="$SIMPLESUITE_INSTALL_SIMPLESERVE" \
        SIMPLESUITE_NETWORK_ROLE="$SIMPLESUITE_NETWORK_ROLE" \
        SIMPLESUITE_INSTALL_SIMPLESERVE_SYSTEM=skip \
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

run_as_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo "$@"
    elif command -v doas >/dev/null 2>&1; then
        doas "$@"
    else
        echo "Root privileges are required to install SimpleSuite in $SYSTEM_BIN_DIR." >&2
        exit 1
    fi
}

simplesuite_program_source() {
    case $1 in
        simplesuite-uninstall)
            printf '%s\n' "$DEST/uninstall.sh"
            ;;
        simplebrowse-webkitd | simplebrowse-jsdump)
            printf '%s\n' "$DEST/$1"
            ;;
        *)
            printf '%s\n' "$DEST/build/$1"
            ;;
    esac
}

install_definitive_program() {
    program=$1

    # simpleserved is deliberately frozen.  SimpleOS owns the installed daemon;
    # Scriptorium must never replace it with the newly fetched upstream build.
    if [ "$program" = simpleserved ]; then
        rm -f "$HOME/.local/bin/simpleserved"
        printf '  preserved: %s\n' "$SYSTEM_DAEMON"
        return 0
    fi

    source_path=$(simplesuite_program_source "$program")
    if [ ! -x "$source_path" ]; then
        echo "Missing SimpleSuite build/install source: $source_path" >&2
        exit 1
    fi

    target_path=$SYSTEM_BIN_DIR/$program
    target_tmp=$SYSTEM_BIN_DIR/.$program.scriptorium.$$

    # Stage first, then atomically replace the bundled SimpleOS copy.  This
    # gives us the intended wipe-and-replace semantics without leaving a
    # missing command if the copy itself fails.
    run_as_root mkdir -p "$SYSTEM_BIN_DIR"
    run_as_root rm -f "$target_tmp"
    run_as_root install -m 0755 "$source_path" "$target_tmp"
    run_as_root mv -f "$target_tmp" "$target_path"

    # Older Scriptorium installs shadowed /usr/local/bin from ~/.local/bin.
    # Remove that second copy so the systemwide install is definitive.
    rm -f "$HOME/.local/bin/$program"
    printf '  replaced: %s\n' "$target_path"
}

if [ -n "$SIMPLESUITE_PROGRAM_FILTER" ]; then
    definitive_programs=$SIMPLESUITE_PROGRAM_FILTER
else
    definitive_programs="$SIMPLESUITE_PROGRAMS $SIMPLESUITE_SCRIPTS"
fi

echo "Installing definitive SimpleSuite in $SYSTEM_BIN_DIR"
for program in $definitive_programs; do
    install_definitive_program "$program"
done

# A previous installer may have left this symlink pointing straight into the
# newly rebuilt tree.  Remove it even when simpleserved was not in this run's
# manifest so the frozen daemon cannot be silently upgraded through PATH.
rm -f "$HOME/.local/bin/simpleserved"

missing=0
echo "Verifying definitive SimpleSuite binaries in $SYSTEM_BIN_DIR"
for program in $definitive_programs; do
    [ "$program" = simpleserved ] && continue
    if [ -x "$SYSTEM_BIN_DIR/$program" ]; then
        printf '  ok: %s\n' "$program"
    else
        printf '  missing: %s\n' "$SYSTEM_BIN_DIR/$program" >&2
        missing=1
    fi
done

if [ "$missing" -ne 0 ]; then
    echo "SimpleSuite definitive install did not produce every expected command." >&2
    exit 1
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

if [ -n "$SIMPLESUITE_PROGRAM_FILTER" ]; then
    exit 0
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

expected_simplewords_version="simplewords $SIMPLESUITE_RESOLVED_SHA"
actual_simplewords_version=$(
    "$SYSTEM_BIN_DIR/simplewords" --version 2>/dev/null || true
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
    Darwin:1:preserve|FreeBSD:1:preserve|Linux:1:preserve)
        # Scriptorium updates applications while SimpleOS owns this daemon.
        # Verify the preserved file, without gating updates on live networking.
        if [ -x "$SYSTEM_DAEMON" ]; then
            printf '  preserved: %s\n' "$SYSTEM_DAEMON"
        else
            echo "Preserved SimpleServe daemon is missing or not executable: $SYSTEM_DAEMON" >&2
            missing=1
        fi
        ;;
    Darwin:1:*|FreeBSD:1:*|Linux:1:*)
        if [ -x "$DEST/verify-simpleserve-system.sh" ] &&
           "$DEST/verify-simpleserve-system.sh" \
               "$SYSTEM_DAEMON" "$SYSTEM_BIN_DIR/simpleserve"; then
            printf '  ok: %s\n' "$SYSTEM_DAEMON"
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
    if [ -x "$SYSTEM_BIN_DIR/simplecal" ]; then
        "$SYSTEM_BIN_DIR/simplecal" --install-reminders || echo "Warning: SimpleCal reminder setup failed; run simplecal --install-reminders later." >&2
    elif command -v simplecal >/dev/null 2>&1; then
        simplecal --install-reminders || echo "Warning: SimpleCal reminder setup failed; run simplecal --install-reminders later." >&2
    fi
fi
