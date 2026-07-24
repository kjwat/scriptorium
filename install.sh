#!/bin/sh
# shellcheck shell=bash

# Alpine's base installation does not include Bash.  Keep this bootstrap in
# POSIX sh so ./install.sh can install Bash before the Bash implementation
# below is parsed.  The other supported platforms provide Bash by default.
# The marker also forces macOS /bin/sh (Bash in POSIX mode) to re-exec as Bash.
if [ "${SCRIPTORIUM_BASH_BOOTSTRAPPED_PID:-}" != "$$" ] ||
   [ -z "${BASH_VERSION:-}" ]; then
    if ! command -v bash >/dev/null 2>&1; then
        if command -v apk >/dev/null 2>&1; then
            if [ "$(id -u)" -eq 0 ]; then
                apk add --no-cache bash || {
                    printf 'Could not install Bash with apk. Check Alpine repositories and network access.\n' >&2
                    exit 1
                }
            elif command -v sudo >/dev/null 2>&1; then
                sudo apk add --no-cache bash || {
                    printf 'Could not install Bash with apk. Check Alpine repositories and network access.\n' >&2
                    exit 1
                }
            else
                printf '%s\n' \
                    'Bash is required, but it is not installed and sudo is unavailable.' \
                    'Run as root or install Bash first with: apk add bash' >&2
                exit 1
            fi
        else
            printf '%s\n' \
                'Bash is required to run the Scriptorium installer.' \
                "Install Bash with this system's package manager, then rerun ./install.sh." >&2
            exit 1
        fi
    fi
    if ! command -v bash >/dev/null 2>&1; then
        printf 'Bash installation completed, but bash is still unavailable on PATH.\n' >&2
        exit 1
    fi
    hash -r 2>/dev/null || true
    SCRIPTORIUM_BASH_BOOTSTRAPPED_PID=$$
    export SCRIPTORIUM_BASH_BOOTSTRAPPED_PID
    exec bash "$0" "$@"
fi
unset SCRIPTORIUM_BASH_BOOTSTRAPPED_PID

set -euo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"

declare -a SHELL_RC_FILES=("$HOME/.bashrc")
ACTIVE_SHELL_RC_NAME=.bashrc
ACTIVE_SHELL_COMMAND=bash
if [[ ${SHELL:-} == */zsh || ${SHELL:-} == zsh ]]; then
    SHELL_RC_FILES+=("$HOME/.zshrc")
    ACTIVE_SHELL_RC_NAME=.zshrc
    ACTIVE_SHELL_COMMAND="${SHELL:-zsh}"
elif [[ ${SHELL:-} == */fish || ${SHELL:-} == fish ]]; then
    SHELL_RC_FILES+=("$HOME/.config/fish/conf.d/scriptorium.fish")
    ACTIVE_SHELL_RC_NAME=.config/fish/conf.d/scriptorium.fish
    ACTIVE_SHELL_COMMAND="${SHELL:-fish}"
fi

say() { printf '\n==> %s\n' "$*"; }
warn() { printf '\n!! %s\n' "$*" >&2; }

run_as_root() {
    if [[ $(id -u) -eq 0 ]]; then
        "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo "$@"
    else
        warn "Root privileges are required, but sudo is not installed."
        warn "Run the installer as root or install/configure sudo first."
        return 127
    fi
}


configure_mbsync_apparmor() {
    local profile local_file tmp enabled

    # Nothing to do on systems without AppArmor tooling.
    command -v apparmor_parser >/dev/null 2>&1 || return 0
    [[ -d /etc/apparmor.d ]] || return 0

    enabled=
    if [[ -r /sys/module/apparmor/parameters/enabled ]]; then
        enabled="$(cat /sys/module/apparmor/parameters/enabled 2>/dev/null || true)"
        [[ "$enabled" == Y* ]] || return 0
    elif command -v aa-status >/dev/null 2>&1; then
        aa-status --enabled >/dev/null 2>&1 || return 0
    else
        return 0
    fi

    # Prefer the conventional packaged profile, then fall back to locating it.
    profile=/etc/apparmor.d/mbsync
    if [[ ! -f "$profile" ]]; then
        profile="$(
            grep -RIlE '(^|[[:space:]])profile[[:space:]]+mbsync|/usr/bin/mbsync' \
                /etc/apparmor.d 2>/dev/null | head -n 1 || true
        )"
    fi

    [[ -n "$profile" && -f "$profile" ]] || return 0

    say "Allowing mbsync to use the SimpleMail Maildir under AppArmor"

    local_file=/etc/apparmor.d/local/mbsync
    run_as_root mkdir -p /etc/apparmor.d/local
    tmp="$(mktemp)"

    if run_as_root test -f "$local_file"; then
        run_as_root cat "$local_file" > "$tmp"
    fi

    if ! grep -Fqx 'owner @{HOME}/.local/share/simplemail/mail/ r,' "$tmp"; then
        printf '%s\n' 'owner @{HOME}/.local/share/simplemail/mail/ r,' >> "$tmp"
    fi
    if ! grep -Fqx 'owner @{HOME}/.local/share/simplemail/mail/** rwk,' "$tmp"; then
        printf '%s\n' 'owner @{HOME}/.local/share/simplemail/mail/** rwk,' >> "$tmp"
    fi

    run_as_root install -m 0644 "$tmp" "$local_file"
    rm -f "$tmp"

    # Packaged Ubuntu profiles normally include this already. Add the include
    # only when a distro ships the profile without a local override hook.
    if ! run_as_root grep -Eq '^[[:space:]]*#include[[:space:]]+(if exists[[:space:]]+)?<local/mbsync>' "$profile"; then
        tmp="$(mktemp)"
        run_as_root awk '
            /^[[:space:]]*}[[:space:]]*$/ && !added {
                print "  #include if exists <local/mbsync>"
                added = 1
            }
            { print }
            END {
                if (!added)
                    exit 1
            }
        ' "$profile" > "$tmp" || {
            rm -f "$tmp"
            warn "Could not add the local AppArmor include to $profile"
            return 0
        }
        run_as_root install -m 0644 "$tmp" "$profile"
        rm -f "$tmp"
    fi

    if ! run_as_root apparmor_parser -r "$profile"; then
        warn "Could not reload the mbsync AppArmor profile; mail sync may remain blocked"
        return 0
    fi
}

disable_stale_apt_cdrom_sources() {
    command -v apt-get >/dev/null 2>&1 || return 0

    local file changed=0 tmp
    local -a apt_source_files=()

    while IFS= read -r -d '' file; do
        apt_source_files+=("$file")
    done < <(
        run_as_root find /etc/apt -maxdepth 3 -type f \
            \( -name '*.list' -o -name '*.sources' \) -print0 2>/dev/null
    )

    for file in "${apt_source_files[@]}"; do
        case "$file" in
            *.list)
                if run_as_root grep -Eq '^[[:space:]]*deb([[:space:]]+\[[^]]*\])?[[:space:]]+cdrom:' "$file"; then
                    say "Disabling stale installation-media repository in $file"
                    run_as_root sed -Ei \
                        '/^[[:space:]]*deb([[:space:]]+\[[^]]*\])?[[:space:]]+cdrom:/ s/^/# disabled by Scriptorium: /' \
                        "$file"
                    changed=1
                fi
                ;;
            *.sources)
                if run_as_root grep -Eqi '^[[:space:]]*URIs:[[:space:]]*cdrom:' "$file"; then
                    say "Disabling stale installation-media repository in $file"
                    tmp="$(mktemp)"
                    # shellcheck disable=SC2016
                    run_as_root awk '
                        BEGIN { RS=""; ORS="\n\n" }
                        {
                            stanza=$0
                            if (stanza ~ /(^|\n)[[:space:]]*URIs:[[:space:]]*cdrom:/ &&
                                stanza !~ /(^|\n)[[:space:]]*Enabled:[[:space:]]*no([[:space:]]|$)/) {
                                print "Enabled: no\n" stanza
                            } else {
                                print stanza
                            }
                        }
                    ' "$file" > "$tmp"
                    run_as_root install -m 0644 "$tmp" "$file"
                    rm -f "$tmp"
                    changed=1
                fi
                ;;
        esac
    done

    if (( changed )); then
        say "Refreshing APT package lists after repository repair"
        run_as_root apt-get update
    fi
}

config_has_key() {
    local file="$1" key="$2"
    [[ -f "$file" ]] || return 1
    awk -F= -v key="$key" '
        /^[[:space:]]*#/ { next }
        NF >= 2 {
            k = $1
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", k)
            if (k == key) found = 1
        }
        END { exit found ? 0 : 1 }
    ' "$file"
}

set_config_key() {
    local file="$1" key="$2" value="$3" tmp

    mkdir -p "$(dirname "$file")"
    if [[ ! -e "$file" ]]; then
        : > "$file"
        CHANGES_MADE=1
    fi

    tmp="$(mktemp "${file}.tmp.XXXXXX")"
    awk -F= -v key="$key" -v value="$value" '
        BEGIN { found = 0 }
        /^[[:space:]]*#/ { print; next }
        NF >= 2 {
            k = $1
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", k)
            if (k == key) {
                if (!found) print key "=" value
                found = 1
                next
            }
        }
        { print }
        END {
            if (!found) print key "=" value
        }
    ' "$file" > "$tmp"

    if cmp -s "$file" "$tmp"; then
        rm -f "$tmp"
    else
        mv "$tmp" "$file"
        CHANGES_MADE=1
    fi
}

ensure_config_key() {
    local file="$1" key="$2" value="$3"

    config_has_key "$file" "$key" || set_config_key "$file" "$key" "$value"
}

ensure_simplesuite_aliases_in_file() {
    local shell_rc="$1"
    local alias_line tmp insert_line
    local aliases=(
        "alias words='simplewords'"
        "alias files='simplefiles'"
        "alias browse='simplebrowse'"
        "alias flac='simpleflac'"
        "alias radio='simpleradio'"
        "alias pod='simplepod'"
        "alias vis='simplevis'"
        "alias clock='simpleclock'"
        "alias check='simplecheck'"
        "alias cal='simplecal'"
        "alias stats='simplestats'"
        "alias ver='simplever'"
        "alias game='simplegame'"
        "alias pdf='simplepdf'"
        "alias news='simplenews'"
        "alias mail='simplemail'"
        "alias net='simplenet'"
    )

    mkdir -p "$(dirname "$shell_rc")"
    touch "$shell_rc"

    if ! grep -qxF "# SimpleSuite aliases" "$shell_rc" 2>/dev/null; then
        {
            printf '\n# SimpleSuite aliases\n'
            printf '%s\n' "${aliases[@]}"
        } >> "$shell_rc"
        CHANGES_MADE=1
        return
    fi

    insert_line=
    for alias_line in "${aliases[@]}"; do
        if ! grep -qxF "$alias_line" "$shell_rc" 2>/dev/null; then
            insert_line+="${alias_line}"$'\n'
        fi
    done

    [[ -n "$insert_line" ]] || return 0

    tmp="$(mktemp "${shell_rc}.tmp.XXXXXX")"
    awk -v insert="$insert_line" '
        {
            print
            if ($0 == "# SimpleSuite aliases" && !inserted) {
                printf "%s", insert
                inserted = 1
            }
        }
    ' "$shell_rc" > "$tmp"
    cat "$tmp" > "$shell_rc"
    rm -f "$tmp"
    CHANGES_MADE=1
}

ensure_simplesuite_aliases() {
    local shell_rc

    for shell_rc in "${SHELL_RC_FILES[@]}"; do
        ensure_simplesuite_aliases_in_file "$shell_rc"
    done
}

ROLLBACK_DIR=
ROLLBACK_ACTIVE=0
CHANGES_MADE=0
LINK_BACKUP_RECORD=
KEEP_ROLLBACK_BACKUP=0
declare -a ROLLBACK_PATHS=()
declare -a ROLLBACK_EXISTED=()
declare -a CREATED_DIRS=()
declare -a EXPECTED_SIMPLESUITE_COMMANDS=(
    simplebrowse
    simplecal
    simpleclock
    simplecheck
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
)
declare -a EXPECTED_SIMPLESUITE_HELPERS=(
    simplebrowse-webkitd
    simplebrowse-jsdump
    simplesuite-uninstall
)

track_path() {
    local path="$1"
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
    local path="$1"
    [[ -d "$path" ]] || CREATED_DIRS+=("$path")
}

prepare_rollback() {
    local git_config_path suite_dir path program shell_rc home_real root_real

    ROLLBACK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/scriptorium-rollback.XXXXXX")"
    chmod 700 "$ROLLBACK_DIR"
    LINK_BACKUP_RECORD="$ROLLBACK_DIR/link-backup"

    git_config_path=${GIT_CONFIG_GLOBAL:-$HOME/.gitconfig}
    suite_dir=${SIMPLESUITE_DIR:-$HOME/simplesuite}
    if [[ "$suite_dir" != /* ]]; then
        suite_dir="$PWD/$suite_dir"
    fi
    if [[ -d "$suite_dir" ]]; then
        suite_dir="$(CDPATH='' cd -- "$suite_dir" && pwd -P)"
    fi
    while [[ "$suite_dir" != / && "$suite_dir" == */ ]]; do
        suite_dir=${suite_dir%/}
    done

    home_real="$(CDPATH='' cd -- "$HOME" && pwd -P)"
    root_real="$(CDPATH='' cd -- "$ROOT" && pwd -P)"
    if [[ "$suite_dir" == / ||
          "$home_real" == "$suite_dir" || "$home_real" == "$suite_dir/"* ||
          "$root_real" == "$suite_dir" || "$root_real" == "$suite_dir/"* ]]; then
        warn "Unsafe SIMPLESUITE_DIR destination: $suite_dir"
        warn "Choose a dedicated SimpleSuite directory, not /, HOME, Scriptorium, or one of their parents."
        return 2
    fi

    track_path "$git_config_path"
    track_path "$ROOT/dotfiles/simplecal/config"
    track_path "$HOME/.git-credentials"
    track_path "$HOME/.config/scriptorium/github-credential-user"
    track_path "$suite_dir"
    for shell_rc in "${SHELL_RC_FILES[@]}"; do
        track_path "$shell_rc"
    done
    track_path "$HOME/.config/simplemail/config"
    track_path "$HOME/.config/simplewords/config"
    track_path "$HOME/.config/simplecal"
    track_path "$HOME/.local/share/simplecal"
    track_path "$HOME/.local/state/simplecal"
    track_path "$HOME/.local/share/simplesuite"
    track_path "$HOME/.config/systemd/user/simplecal-reminders.service"
    track_path "$HOME/.config/systemd/user/simplecal-reminders.timer"
    track_path "$HOME/.msmtprc"
    track_path "$HOME/.mbsyncrc"
    track_path "$HOME/.config/isyncrc"
    track_path "$HOME/.config/calcurse"
    track_path "$HOME/.links"
    track_path "$HOME/.config/simplefiles/config"
    track_path "$HOME/.config/simplenews/config"
    track_path "$HOME/.config/simplenews/urls"
    track_path "$HOME/.config/simplenews/config.example"
    track_path "$HOME/.config/simplenews/urls.example"
    track_path "$HOME/.config/simplesuite/family"

    for program in "${EXPECTED_SIMPLESUITE_COMMANDS[@]}" \
                   "${EXPECTED_SIMPLESUITE_HELPERS[@]}"; do
        track_path "$HOME/.local/bin/$program"
    done

    for path in \
        "$HOME/.local" \
        "$HOME/.local/bin" \
        "$HOME/.local/share" \
        "$HOME/.local/share/simplecal" \
        "$HOME/.local/share/simplemail" \
        "$HOME/.local/share/simplemail/mail" \
        "$HOME/.local/share/simplemail/mail/Inbox" \
        "$HOME/.local/share/simplemail/mail/Inbox/cur" \
        "$HOME/.local/share/simplemail/mail/Inbox/new" \
        "$HOME/.local/share/simplemail/mail/Inbox/tmp" \
        "$HOME/.local/share/simplemail/mail/Sent" \
        "$HOME/.local/share/simplemail/mail/Sent/cur" \
        "$HOME/.local/share/simplemail/mail/Sent/new" \
        "$HOME/.local/share/simplemail/mail/Sent/tmp" \
        "$HOME/.local/share/simplemail/mail/Drafts" \
        "$HOME/.local/share/simplemail/mail/Drafts/cur" \
        "$HOME/.local/share/simplemail/mail/Drafts/new" \
        "$HOME/.local/share/simplemail/mail/Drafts/tmp" \
        "$HOME/.local/share/simplemail/mail/Archive" \
        "$HOME/.local/share/simplemail/mail/Archive/cur" \
        "$HOME/.local/share/simplemail/mail/Archive/new" \
        "$HOME/.local/share/simplemail/mail/Archive/tmp" \
        "$HOME/.local/share/simplemail/mail/Trash" \
        "$HOME/.local/share/simplemail/mail/Trash/cur" \
        "$HOME/.local/share/simplemail/mail/Trash/new" \
        "$HOME/.local/share/simplemail/mail/Trash/tmp" \
        "$HOME/.local/share/simplesuite" \
        "$HOME/.local/state" \
        "$HOME/.local/state/simplecal" \
        "$HOME/.config" \
        "$HOME/.config/scriptorium" \
        "$HOME/.config/simplesuite" \
        "$HOME/.config/simplefiles" \
        "$HOME/.config/simplenews" \
        "$HOME/.config/simplemail" \
        "$HOME/.config/simplewords" \
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

    if [[ -r /dev/tty ]] && IFS= read -r answer 2>/dev/null < /dev/tty; then
        :
    else
        IFS= read -r answer || answer=
    fi

    case "$answer" in
        y | Y | yes | YES)
            if restore_tracked_changes; then
                printf 'Rolled back Git and Scriptorium user-file changes.\n' >&2
                printf 'System and package-manager changes, if any, were not rolled back.\n' >&2
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

say "Installing package dependencies"
CHANGES_MADE=1
disable_stale_apt_cdrom_sources
"$ROOT/scripts/install-packages.sh"

configure_mbsync_apparmor

for required_command in git curl; do
    if ! command -v "$required_command" >/dev/null 2>&1; then
        warn "$required_command is still unavailable after dependency installation."
        exit 1
    fi
done

git_name="$(git config --global --get user.name 2>/dev/null || true)"
git_email="$(git config --global --get user.email 2>/dev/null || true)"

while [[ -z "${git_name//[[:space:]]/}" ]]; do
    IFS= read -r -p "Enter your Git name: " git_name
    if [[ -z "${git_name//[[:space:]]/}" ]]; then
        warn "Git name cannot be blank."
    fi
done

while [[ -z "${git_email//[[:space:]]/}" ]]; do
    IFS= read -r -p "Enter your Git email: " git_email
    if [[ -z "${git_email//[[:space:]]/}" ]]; then
        warn "Git email cannot be blank."
    elif [[ ! "$git_email" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]; then
        warn "That does not look like a complete email address."
        git_email=
    fi
done

git config --global user.name "$git_name"
git config --global user.email "$git_email"
CHANGES_MADE=1

saved_git_name="$(git config --global --get user.name 2>/dev/null || true)"
saved_git_email="$(git config --global --get user.email 2>/dev/null || true)"
if [[ -z "${saved_git_name//[[:space:]]/}" || -z "${saved_git_email//[[:space:]]/}" ]]; then
    warn "Git identity was not saved correctly. Installation cannot continue."
    exit 1
fi

printf 'Git identity: %s <%s>\n' "$saved_git_name" "$saved_git_email"

say "Configuring Git"
CHANGES_MADE=1
git config --global credential.helper store
git config --global pull.rebase true
git config --global rebase.autoStash true
printf 'Git pull mode: rebase with autostash\n'

say "Configuring GitHub credentials"

while :; do
    IFS= read -r -p "Enter your GitHub username (leave blank to skip): " github_user
    github_user="${github_user#"${github_user%%[![:space:]]*}"}"
    github_user="${github_user%"${github_user##*[![:space:]]}"}"

    if [[ -z "$github_user" ]]; then
        break
    fi

    if [[ ! "$github_user" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,37}[A-Za-z0-9])?$ ]]; then
        warn "That is not a valid GitHub username."
        continue
    fi

    break
done

if [[ -z "$github_user" ]]; then
    printf 'GitHub credential setup skipped. Public clones still work; configure authentication before pushing.\n'
else
    while :; do
        IFS= read -r -s -p "Paste your GitHub PAT: " github_pat
        printf '\n'
        github_pat="$(printf '%s' "$github_pat" | tr -d '\r\n')"

        if [[ -z "$github_pat" ]]; then
            warn "GitHub PAT cannot be blank after choosing a GitHub username."
            continue
        fi

        break
    done

    github_response="$(mktemp "${TMPDIR:-/tmp}/scriptorium-github.XXXXXX")"
    github_http_code="$(
        curl -sS -o "$github_response" -w '%{http_code}' \
            -H "Authorization: Bearer $github_pat" \
            -H "Accept: application/vnd.github+json" \
            https://api.github.com/user 2>/dev/null || true
    )"
    github_login="$(
        sed -n 's/^[[:space:]]*"login":[[:space:]]*"\([^"]*\)".*/\1/p' "$github_response" |
        head -n 1
    )"
    rm -f "$github_response"

    case "$github_http_code" in
        200)
            if [[ -z "$github_login" ]]; then
                unset github_pat
                warn "GitHub returned an unexpected authentication response."
                exit 1
            fi
            if [[ "$github_login" != "$github_user" ]]; then
                unset github_pat
                warn "That PAT belongs to '$github_login', not '$github_user'."
                exit 1
            fi
            printf 'Authenticated with GitHub as %s.\n' "$github_login"
            ;;
        401 | 403)
            unset github_pat
            warn "GitHub rejected that PAT (HTTP $github_http_code)."
            exit 1
            ;;
        *)
            warn "GitHub credential validation was unavailable (HTTP ${github_http_code:-000})."
            warn "Storing the credential as entered; Git will verify it on first use."
            ;;
    esac

    printf 'protocol=https\nhost=github.com\nusername=%s\npassword=%s\n\n' \
        "$github_user" "$github_pat" |
    git credential-store --file "$HOME/.git-credentials" store
    chmod 600 "$HOME/.git-credentials" 2>/dev/null || true
    mkdir -p "$HOME/.config/scriptorium"
    printf '%s\n' "$github_user" > "$HOME/.config/scriptorium/github-credential-user"
    chmod 600 "$HOME/.config/scriptorium/github-credential-user"
    unset github_pat
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

for shell_rc in "${SHELL_RC_FILES[@]}"; do
    mkdir -p "$(dirname "$shell_rc")"
    if [[ $shell_rc == *.fish ]]; then
        path_line='fish_add_path --path "$HOME/.local/bin"'
    else
        path_line='export PATH="$HOME/.local/bin:$PATH"'
    fi
    grep -qxF "$path_line" "$shell_rc" 2>/dev/null || {
        printf '\n# Scriptorium user binaries\n%s\n' "$path_line" >> "$shell_rc"
        CHANGES_MADE=1
    }
done

ensure_simplesuite_aliases

export PATH="$HOME/.local/bin:$PATH"
hash -r

say "Installing SimpleSuite"
SIMPLESUITE_INSTALL_REMINDERS=0 "$ROOT/scripts/install-simplesuite.sh"

say "Installing SimpleCheck"
"$ROOT/scripts/install-simplecheck.sh"

say "Configuring SimpleCal"
mkdir -p "$ROOT/dotfiles/simplecal/data"
set_config_key "$ROOT/dotfiles/simplecal/config" "data_dir" "data"
ensure_config_key "$ROOT/dotfiles/simplecal/config" "default_reminder_lead_times" "10,30,60"
ensure_config_key "$ROOT/dotfiles/simplecal/config" "theme" "default"
ensure_config_key "$ROOT/dotfiles/simplecal/config" "today_color" "yellow"
ensure_config_key "$ROOT/dotfiles/simplecal/config" "first_day_of_week" "sunday"
ensure_config_key "$ROOT/dotfiles/simplecal/config" "clock" "24h"
ensure_config_key "$ROOT/dotfiles/simplecal/config" "reminders_auto_install_attempted" "0"
ensure_config_key "$ROOT/dotfiles/simplecal/config" "legacy_migration_warned" "0"

say "Linking dotfiles"
SCRIPTORIUM_LINK_BACKUP_RECORD="$LINK_BACKUP_RECORD" \
    "$ROOT/scripts/link-dotfiles.sh"



say "Creating standard directories"
mkdir -p "$HOME/Downloads" "$HOME/Music" "$HOME/Podcasts"


say "Verifying commands"
for cmd in "${EXPECTED_SIMPLESUITE_COMMANDS[@]}"; do
    command -v "$cmd" >/dev/null 2>&1 || {
        warn "$cmd was installed but is not available on PATH"
        exit 1
    }
done
for cmd in "${EXPECTED_SIMPLESUITE_HELPERS[@]}"; do
    command -v "$cmd" >/dev/null 2>&1 || {
        warn "$cmd was installed but is not available on PATH"
        exit 1
    }
done

say "Installing SimpleCal reminder backend"
if ! "$HOME/.local/bin/simplecal" --install-reminders; then
    warn "SimpleCal reminder setup failed; run 'simplecal --install-reminders' later."
fi

say "Installed SimpleSuite tools"
for cmd in "${EXPECTED_SIMPLESUITE_COMMANDS[@]}"; do
    printf '  %s\n' "$cmd"
done

say "Done. The Scriptorium is installed."
cleanup_rollback
trap - EXIT INT TERM

if [[ -t 0 ]]; then
    printf 'Starting a configured shell; words and simplewords are ready to use.\n'
    exec "$ACTIVE_SHELL_COMMAND" -i
fi

# shellcheck disable=SC2016
printf 'Open a new terminal or run: source "$HOME/%s"\n' "$ACTIVE_SHELL_RC_NAME"
