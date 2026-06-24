#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

say() { printf '\n==> %s\n' "$*"; }
warn() { printf '\n!! %s\n' "$*" >&2; }

ROLLBACK_DIR=
ROLLBACK_ACTIVE=0
CHANGES_MADE=0
LINK_BACKUP_RECORD=
KEEP_ROLLBACK_BACKUP=0
declare -a ROLLBACK_PATHS=()
declare -a ROLLBACK_EXISTED=()
declare -a CREATED_DIRS=()

track_path() {
    local path=$1
    local index=${#ROLLBACK_PATHS[@]}

    ROLLBACK_PATHS+=("$path")
    printf '%s\t%s\n' "$index" "$path" >> "$ROLLBACK_DIR/manifest"
    if [[ -e "$path" || -L "$path" ]]; then
        cp -a "$path" "$ROLLBACK_DIR/$index"
        ROLLBACK_EXISTED+=(1)
    else
        ROLLBACK_EXISTED+=(0)
    fi
}

track_created_dir() {
    local path=$1
    [[ -d "$path" ]] || CREATED_DIRS+=("$path")
}

prepare_rollback() {
    local git_config_path suite_dir path program

    ROLLBACK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/scriptorium-rollback.XXXXXX")"
    chmod 700 "$ROLLBACK_DIR"
    LINK_BACKUP_RECORD="$ROLLBACK_DIR/link-backup"

    git_config_path=${GIT_CONFIG_GLOBAL:-$HOME/.gitconfig}
    suite_dir=${SIMPLESUITE_DIR:-$HOME/simplesuite}
    if [[ "$suite_dir" != /* ]]; then
        suite_dir="$PWD/$suite_dir"
    fi

    track_path "$git_config_path"
    track_path "$HOME/.git-credentials"
    track_path "$suite_dir"
    track_path "$HOME/.bashrc"
    track_path "$HOME/.config/simplemail/config"
    track_path "$HOME/.msmtprc"
    track_path "$HOME/.mbsyncrc"
    track_path "$HOME/.config/calcurse"
    track_path "$HOME/.links"
    track_path "$HOME/.config/simplefiles/config"
    track_path "$HOME/.config/simplenews/config"
    track_path "$HOME/.config/simplenews/urls"
    track_path "$HOME/.config/simplenews/config.example"
    track_path "$HOME/.config/simplenews/urls.example"

    for program in \
        simpleclock simplefiles simpleflac simplegame simplepdf simplepod \
        simpleradio simplenews simplestats simplever simplevis simplewords; do
        track_path "$HOME/.local/bin/$program"
    done

    for path in \
        "$HOME/.local" \
        "$HOME/.local/bin" \
        "$HOME/.config" \
        "$HOME/.config/simplefiles" \
        "$HOME/.config/simplenews" \
        "$HOME/.config/simplemail" \
        "$HOME/Downloads" \
        "$HOME/Music" \
        "$HOME/Podcasts"; do
        track_created_dir "$path"
    done

    ROLLBACK_ACTIVE=1
}

restore_tracked_changes() {
    local index path backup_path link_backup restore_failed=0

    set +e
    for ((index = ${#ROLLBACK_PATHS[@]} - 1; index >= 0; index--)); do
        path=${ROLLBACK_PATHS[index]}
        backup_path="$ROLLBACK_DIR/$index"

        if [[ -e "$path" || -L "$path" ]]; then
            rm -rf "$path" || restore_failed=1
        fi
        if [[ ${ROLLBACK_EXISTED[index]} -eq 1 ]]; then
            mkdir -p "$(dirname "$path")" || restore_failed=1
            cp -a "$backup_path" "$path" || restore_failed=1
        fi
    done

    if [[ -s "$LINK_BACKUP_RECORD" ]]; then
        IFS= read -r link_backup < "$LINK_BACKUP_RECORD"
        case "$link_backup" in
            "$HOME/.scriptorium-backups/"*)
                rm -rf "$link_backup" || restore_failed=1
                ;;
        esac
    fi

    for ((index = ${#CREATED_DIRS[@]} - 1; index >= 0; index--)); do
        rmdir "${CREATED_DIRS[index]}" 2>/dev/null || true
    done
    set -e
    return "$restore_failed"
}

cleanup_rollback() {
    if [[ -n "$ROLLBACK_DIR" && -d "$ROLLBACK_DIR" ]]; then
        rm -rf "$ROLLBACK_DIR"
    fi
    ROLLBACK_DIR=
    ROLLBACK_ACTIVE=0
}

prompt_for_rollback() {
    local answer=

    printf '\n!! Installation failed.\n' >&2
    printf 'Roll back Git configuration, Scriptorium user files, symlinks, and dotfiles? [y/N] ' >&2

    if [[ -r /dev/tty ]]; then
        IFS= read -r answer < /dev/tty || answer=
    else
        IFS= read -r answer || answer=
    fi

    case "$answer" in
        y | Y | yes | YES)
            if restore_tracked_changes; then
                printf 'Rolled back Git and Scriptorium user-file changes.\n' >&2
                printf 'Package-manager changes, if any, were not rolled back.\n' >&2
            else
                KEEP_ROLLBACK_BACKUP=1
                printf 'Rollback was incomplete. Recovery copies remain in: %s\n' \
                    "$ROLLBACK_DIR" >&2
            fi
            ;;
        *)
            printf 'Rollback skipped.\n' >&2
            ;;
    esac
}

installer_exit() {
    local status=$?

    trap - EXIT INT TERM
    stty echo 2>/dev/null || true
    set +e

    if [[ $status -ne 0 && $ROLLBACK_ACTIVE -eq 1 && $CHANGES_MADE -eq 1 ]]; then
        prompt_for_rollback
    fi
    if [[ $KEEP_ROLLBACK_BACKUP -eq 0 ]]; then
        cleanup_rollback
    fi
    exit "$status"
}

trap installer_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

prepare_rollback

say "Scriptorium installer"

if ! git config --global user.name >/dev/null 2>&1; then
    printf "Enter your Git name: "
    read -r git_name
    CHANGES_MADE=1
    git config --global user.name "$git_name"
fi

if ! git config --global user.email >/dev/null 2>&1; then
    printf "Enter your Git email: "
    read -r git_email
    CHANGES_MADE=1
    git config --global user.email "$git_email"
fi

say "Configuring GitHub credentials"
CHANGES_MADE=1
git config --global credential.helper store

printf "Enter your GitHub username: "
read -r github_user

printf "Paste your GitHub PAT: "
stty -echo
read -r github_pat
stty echo
printf '\n'
github_pat="$(printf '%s' "$github_pat" | tr -d '\r\n')"
stty echo
printf '\n'

if [ -n "$github_user" ] && [ -n "$github_pat" ]; then
    printf 'protocol=https\nhost=github.com\nusername=%s\npassword=%s\n\n' "$github_user" "$github_pat" |
        git credential-store --file "$HOME/.git-credentials" store
    chmod 600 "$HOME/.git-credentials" 2>/dev/null || true
fi


printf "\nDo you want to configure SimpleMail for Gmail IMAP/SMTP? [y/N] "
read -r setup_gmail

case "$setup_gmail" in
    y|Y|yes|YES)
        "$ROOT/scripts/setup-simplemail-gmail.sh"
        CHANGES_MADE=1
        ;;
esac




say "Preparing user PATH"
mkdir -p "$HOME/.local/bin"

PATH_LINE='export PATH="$HOME/.local/bin:$PATH"'

grep -qxF "$PATH_LINE" "$HOME/.bashrc" 2>/dev/null || {
    printf '\n# Scriptorium user binaries\n%s\n' "$PATH_LINE" >> "$HOME/.bashrc"
}

grep -q "^# SimpleSuite aliases$" "$HOME/.bashrc" 2>/dev/null || cat >> "$HOME/.bashrc" <<'ALIASES'

# SimpleSuite aliases
alias words='simplewords'
alias files='simplefiles'
alias flac='simpleflac'
alias radio='simpleradio'
alias pod='simplepod'
alias vis='simplevis'
alias clock='simpleclock'
alias stats='simplestats'
alias ver='simplever'
alias game='simplegame'
alias pdf='simplepdf'
alias news='simplenews'
alias mail='simplemail'
ALIASES

export PATH="$HOME/.local/bin:$PATH"
hash -r

say "Installing package dependencies"
"$ROOT/scripts/install-packages.sh"



say "Installing SimpleSuite"
"$ROOT/scripts/install-simplesuite.sh"

say "Linking dotfiles"
SCRIPTORIUM_LINK_BACKUP_RECORD="$LINK_BACKUP_RECORD" \
    "$ROOT/scripts/link-dotfiles.sh"



say "Creating standard directories"
mkdir -p "$HOME/Downloads" "$HOME/Music" "$HOME/Podcasts"


say "Verifying commands"
for cmd in simplewords simplefiles simplever simpleflac simpleradio simplepod simplepdf simplestats simpleclock simplegame simplevis mbsync msmtp calcurse links git mpv fzf; do
    command -v "$cmd" >/dev/null 2>&1 || {
        warn "$cmd was installed but is not available on PATH"
        exit 1
    }
done

say "Done. The Scriptorium is installed."
cleanup_rollback
trap - EXIT INT TERM
exec bash -l
