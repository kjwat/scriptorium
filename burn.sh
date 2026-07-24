#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
SIMPLESUITE_DEST="${SIMPLESUITE_DIR:-$HOME/simplesuite}"

if [ -d "$SIMPLESUITE_DEST" ]; then
    SIMPLESUITE_DEST="$(CDPATH='' cd -- "$SIMPLESUITE_DEST" && pwd -P)"
fi
while [ "$SIMPLESUITE_DEST" != / ] && [ "${SIMPLESUITE_DEST%/}" != "$SIMPLESUITE_DEST" ]; do
    SIMPLESUITE_DEST=${SIMPLESUITE_DEST%/}
done

HOME_REAL="$(CDPATH='' cd -- "$HOME" && pwd -P)"
ROOT_REAL="$(CDPATH='' cd -- "$ROOT" && pwd -P)"
case "$HOME_REAL/" in
    "$SIMPLESUITE_DEST/"*) unsafe_simplesuite_dest=1 ;;
    *) unsafe_simplesuite_dest=0 ;;
esac
case "$ROOT_REAL/" in
    "$SIMPLESUITE_DEST/"*) unsafe_simplesuite_dest=1 ;;
esac
if [ "$SIMPLESUITE_DEST" = / ] || [ "$unsafe_simplesuite_dest" -eq 1 ]; then
    printf 'Refusing unsafe SIMPLESUITE_DIR destination: %s\n' "$SIMPLESUITE_DEST" >&2
    exit 2
fi

run_as_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo "$@"
    else
        printf 'Root privileges are required to remove system packages.\n' >&2
        return 127
    fi
}

clean_scriptorium_credentials() {
    credential_user=kjwat
    credential_marker="$HOME/.config/scriptorium/github-credential-user"

    if [ -s "$credential_marker" ]; then
        IFS= read -r credential_user < "$credential_marker" || credential_user=kjwat
    fi

    if [ -n "$credential_user" ] && [ -f "$HOME/.git-credentials" ] &&
       command -v git >/dev/null 2>&1; then
        printf 'protocol=https\nhost=github.com\nusername=%s\n\n' "$credential_user" |
            git credential-store --file "$HOME/.git-credentials" erase || true
        if [ ! -s "$HOME/.git-credentials" ]; then
            rm -f "$HOME/.git-credentials"
        else
            chmod 600 "$HOME/.git-credentials"
        fi
    fi

    rm -f "$credential_marker"
    rmdir "$HOME/.config/scriptorium" 2>/dev/null || true
}

run_simplesuite_burn() {
    suite_uninstaller=

    if [ -x "$HOME/.local/bin/simplesuite-uninstall" ]; then
        suite_uninstaller=$HOME/.local/bin/simplesuite-uninstall
    elif [ -x "$SIMPLESUITE_DEST/uninstall.sh" ]; then
        suite_uninstaller=$SIMPLESUITE_DEST/uninstall.sh
    fi

    [ -n "$suite_uninstaller" ] || return 0

    echo "Burning the installed SimpleSuite payload and data"
    if ! (
        unset BINDIR DATADIR SIMPLESUITE_DATADIR DESTDIR
        PREFIX="$HOME/.local"
        export PREFIX
        "$suite_uninstaller" --burn --yes
    ); then
        printf 'SimpleSuite native burn failed; continuing with Scriptorium fallback cleanup.\n' >&2
    fi
}

echo
echo "BURN MODE"
echo
printf "Type BURN to continue: "
read -r ans

[ "$ans" = "BURN" ] || exit 1

if [ -x "$ROOT/burn-writing.sh" ]; then
    WRITING_DIR="${WRITING_DIR:-$HOME/writing}" "$ROOT/burn-writing.sh" <<'BURNINPUT' || true
BURN-WRITING
BURNINPUT
else
    rm -rf "$HOME/writing"
fi

run_simplesuite_burn

rm -rf "$SIMPLESUITE_DEST" "$HOME/src/simplesuite"
rm -rf "$HOME/.writing-clone-tmp"

for bin in simplewords simplecheck simplefiles simplebrowse simplebrowse-webkitd simplebrowse-jsdump simplesuite-uninstall simpleflac simpleradio simplepod simplevis simplepdf simpleclock simplecal simplestats simplever simplegame simplenews simplemail simplenet; do
    rm -f "$HOME/.local/bin/$bin"
done

# Remove snapd itself only if Scriptorium installed it.
if [ -f "$HOME/.config/scriptorium/snapd-installed" ]; then
    if command -v apt-get >/dev/null 2>&1; then
        run_as_root apt-get purge -y snapd || true
        run_as_root apt-get autoremove -y || true
    elif command -v dnf >/dev/null 2>&1; then
        run_as_root dnf remove -y snapd || true
    fi
    rm -rf "$HOME/snap"
    rm -f "$HOME/.config/scriptorium/snapd-installed"
fi

rm -rf "$HOME/.config/calcurse"
rm -rf "$HOME/.config/simplebrowse"
rm -rf "$HOME/.config/simplefiles"
rm -rf "$HOME/.config/simplepod"
rm -rf "$HOME/.config/simplewords"
rm -rf "$HOME/.config/simplecal"
rm -rf "$HOME/.local/share/simplecal"
rm -rf "$HOME/.local/state/simplecal"
rm -rf "$HOME/.local/state/simpleclock"
rm -rf "$HOME/.local/share/simplesuite"
if command -v systemctl >/dev/null 2>&1; then
    systemctl --user disable --now \
        simplecal-reminders.timer simplecal-reminders.service \
        simpleclock-reminders.timer simpleclock-reminders.service \
        >/dev/null 2>&1 || true
    systemctl --user daemon-reload >/dev/null 2>&1 || true
fi
rm -f "$HOME/.config/systemd/user/simplecal-reminders.service"
rm -f "$HOME/.config/systemd/user/simplecal-reminders.timer"
rm -f "$HOME/.config/systemd/user/simpleclock-reminders.service"
rm -f "$HOME/.config/systemd/user/simpleclock-reminders.timer"
if command -v crontab >/dev/null 2>&1; then
    tmp_cron="$(mktemp)"
    crontab -l 2>/dev/null | \
        grep -v -e "simplecal --check-reminders" \
                -e "simpleclock --check-reminders" > "$tmp_cron" || true
    crontab "$tmp_cron" 2>/dev/null || true
    rm -f "$tmp_cron"
fi
rm -rf "$HOME/.config/simplenews"
rm -rf "$HOME/.cache/simplenews"

remove_scriptorium_mail_block() {
    file=$1
    begin=$2
    end=$3

    [ -f "$file" ] || return 0
    tmp="$(mktemp)"
    awk -v b="$begin" -v e="$end" '
        $0 == b { skip=1; next }
        $0 == e { skip=0; next }
        !skip { print }
    ' "$file" > "$tmp"
    cat "$tmp" > "$file"
    rm -f "$tmp"
    if [ ! -s "$file" ]; then
        rm -f "$file"
    fi
}

remove_scriptorium_mail_block "$HOME/.mbsyncrc" "# BEGIN SCRIPTORIUM SIMPLEMAIL GMAIL" "# END SCRIPTORIUM SIMPLEMAIL GMAIL"
remove_scriptorium_mail_block "$HOME/.msmtprc" "# BEGIN SCRIPTORIUM SIMPLEMAIL GMAIL" "# END SCRIPTORIUM SIMPLEMAIL GMAIL"
rm -f "$HOME/.config/isyncrc"
rm -rf "$HOME/.config/simplemail"

rm -rf "$HOME/.links"
rm -rf "$HOME/.cache/simplebrowse"
rm -rf "$HOME/.cache/simplefiles"
rm -rf "$HOME/.cache/simplemail"
rm -rf "$HOME/.cache/simplepod"
rm -rf "$HOME/.cache/simplewords"
rm -f "$HOME/.cache/simplever.log"
rm -rf "$HOME/.local/share/simplebrowse"
rm -rf "$HOME/.local/share/simplefiles"
rm -rf "$HOME/.local/share/simplemail"
rm -rf "$HOME/.local/state/simplefiles"
rm -rf "$HOME/.local/state/simplemail"
rm -rf "$HOME/.local/state/simplepod"
rm -rf "$HOME/.local/state/simplever"
rm -rf "$HOME/.local/state/simplewords"
rm -rf "$HOME/.config/simplecheck"
rm -rf "$HOME/.cache/simplecheck"
rm -rf "$HOME/.local/state/simplecheck"
rm -f "$HOME/.simplewords-session"
rm -f "$HOME/.simpleclock-alarm"
rm -f "$HOME/.simpleclock-alarm-worker"
rm -f "$HOME/.simpleclock-alarm.tmp"

if command -v git >/dev/null 2>&1; then
    git_name="$(git config --global user.name 2>/dev/null || true)"
    git_email="$(git config --global user.email 2>/dev/null || true)"

    case "$git_name" in
        "kjwat"|"Keelan Watlington")
            git config --global --unset user.name || true
            ;;
    esac

    case "$git_email" in
        *kjwat*)
            git config --global --unset user.email || true
            ;;
    esac
fi

clean_shell_rc() {
    file=$1
    [ -f "$file" ] || return 0

    tmp="$(mktemp)"
    awk '
        BEGIN {
            aliases["words"] = "simplewords"
            aliases["files"] = "simplefiles"
            aliases["browse"] = "simplebrowse"
            aliases["flac"] = "simpleflac"
            aliases["radio"] = "simpleradio"
            aliases["pod"] = "simplepod"
            aliases["vis"] = "simplevis"
            aliases["clock"] = "simpleclock"
            aliases["check"] = "simplecheck"
            aliases["cal"] = "simplecal"
            aliases["stats"] = "simplestats"
            aliases["ver"] = "simplever"
            aliases["game"] = "simplegame"
            aliases["pdf"] = "simplepdf"
            aliases["news"] = "simplenews"
            aliases["mail"] = "simplemail"
            aliases["net"] = "simplenet"
            quote = sprintf("%c", 39)
        }
        $0 == "# Scriptorium user binaries" { next }
        $0 == "export PATH=\"$HOME/.local/bin:$PATH\"" { next }
        $0 == "fish_add_path --path \"$HOME/.local/bin\"" { next }
        $0 == "# SimpleSuite aliases" { next }
        $1 == "alias" {
            split($2, pair, "=")
            value = pair[2]
            gsub(quote, "", value)
            if (pair[1] in aliases && value == aliases[pair[1]]) next
        }
        { print }
    ' "$file" > "$tmp"
    cat "$tmp" > "$file"
    rm -f "$tmp"
}

clean_shell_rc "$HOME/.bashrc"
clean_shell_rc "$HOME/.zshrc"
clean_shell_rc "$HOME/.config/fish/conf.d/scriptorium.fish"

# Remove only the GitHub credential recorded by this Scriptorium install.
clean_scriptorium_credentials
rm -rf "$HOME/.config/scriptorium"
rm -rf "$HOME/.config/simplesuite"
rm -rf "$HOME/.scriptorium-backups"

cd "$HOME"
rm -rf "$ROOT"

echo
echo "Burn complete."
