#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

clean_kjwat_credentials() {
    if [ -f "$HOME/.git-credentials" ]; then
        tmp="$(mktemp)"
        grep -vE 'github\.com.*kjwat|kjwat.*github\.com' "$HOME/.git-credentials" > "$tmp" || true
        mv "$tmp" "$HOME/.git-credentials"
        chmod 600 "$HOME/.git-credentials"
    fi

    if command -v git >/dev/null 2>&1; then
        printf 'protocol=https\nhost=github.com\nusername=kjwat\n\n' | git credential reject || true
        printf 'protocol=https\nhost=github.com\npath=kjwat/scriptorium\n\n' | git credential reject || true
        printf 'protocol=https\nhost=github.com\npath=kjwat/simplesuite\n\n' | git credential reject || true
        printf 'protocol=https\nhost=github.com\npath=kjwat/writing\n\n' | git credential reject || true
    fi
}

echo
echo "BURN MODE"
echo
printf "Type BURN to continue: "
read ans

[ "$ans" = "BURN" ] || exit 1

if [ -x "$ROOT/burn-writing.sh" ]; then
    WRITING_DIR="${WRITING_DIR:-$HOME/writing}" "$ROOT/burn-writing.sh" <<'BURNINPUT' || true
BURN-WRITING
BURNINPUT
else
    rm -rf "$HOME/writing"
fi

rm -rf "$HOME/simplesuite" "$HOME/src/simplesuite"

for bin in simplewords simplefiles simpleflac simpleradio simplepod simplevis simplepdf simpleclock simplecal simplestats simplever simplegame simplenews simplemail; do
    rm -f "$HOME/.local/bin/$bin"
done


# Remove snapd itself only if Scriptorium installed it.
if [ -f "$HOME/.config/scriptorium/snapd-installed" ]; then
    if command -v apt >/dev/null 2>&1; then
        sudo apt purge -y snapd || true
        sudo apt autoremove -y || true
    elif command -v dnf >/dev/null 2>&1; then
        sudo dnf remove -y snapd || true
    fi
    rm -rf "$HOME/snap"
    rm -f "$HOME/.config/scriptorium/snapd-installed"
fi

rm -rf "$HOME/.config/calcurse"
rm -rf "$HOME/.config/simplefiles"
rm -rf "$HOME/.config/simplepod"
rm -rf "$HOME/.config/simplecal"
rm -rf "$HOME/.local/state/simplecal"
rm -f "$HOME/.local/share/simplesuite/simplecal-alarm.mp3"
if command -v systemctl >/dev/null 2>&1; then
    systemctl --user disable --now simplecal-reminders.timer >/dev/null 2>&1 || true
    systemctl --user daemon-reload >/dev/null 2>&1 || true
fi
rm -f "$HOME/.config/systemd/user/simplecal-reminders.service"
rm -f "$HOME/.config/systemd/user/simplecal-reminders.timer"
if command -v crontab >/dev/null 2>&1; then
    tmp_cron="$(mktemp)"
    crontab -l 2>/dev/null | grep -v "simplecal --check-reminders" > "$tmp_cron" || true
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
}

remove_scriptorium_mail_block "$HOME/.mbsyncrc" "# BEGIN SCRIPTORIUM SIMPLEMAIL GMAIL" "# END SCRIPTORIUM SIMPLEMAIL GMAIL"
remove_scriptorium_mail_block "$HOME/.msmtprc" "# BEGIN SCRIPTORIUM SIMPLEMAIL GMAIL" "# END SCRIPTORIUM SIMPLEMAIL GMAIL"
rm -rf "$HOME/.config/simplemail"



rm -rf "$HOME/.links"
rm -rf "$HOME/.cache/simplefiles"
rm -rf "$HOME/.local/share/simplefiles"

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

if [ -f "$HOME/.bashrc" ]; then
    sed -i '/# Scriptorium user binaries/d' "$HOME/.bashrc"
    sed -i '/export PATH="\$HOME\/.local\/bin:\$PATH"/d' "$HOME/.bashrc"

    sed -i '/# SimpleSuite aliases/d' "$HOME/.bashrc"
    sed -i "/alias words='simplewords'/d" "$HOME/.bashrc"
    sed -i "/alias files='simplefiles'/d" "$HOME/.bashrc"
    sed -i "/alias flac='simpleflac'/d" "$HOME/.bashrc"
    sed -i "/alias radio='simpleradio'/d" "$HOME/.bashrc"
    sed -i "/alias pod='simplepod'/d" "$HOME/.bashrc"
    sed -i "/alias vis='simplevis'/d" "$HOME/.bashrc"
    sed -i "/alias clock='simpleclock'/d" "$HOME/.bashrc"
    sed -i "/alias cal='simplecal'/d" "$HOME/.bashrc"
    sed -i "/alias stats='simplestats'/d" "$HOME/.bashrc"
    sed -i "/alias ver='simplever'/d" "$HOME/.bashrc"
    sed -i "/alias game='simplegame'/d" "$HOME/.bashrc"
    sed -i "/alias pdf='simplepdf'/d" "$HOME/.bashrc"
    sed -i "/alias news='simplenews'/d" "$HOME/.bashrc"
    sed -i "/alias mail='simplemail'/d" "$HOME/.bashrc"
fi

# Remove credential helper and stored PATs.
if command -v git >/dev/null 2>&1; then
    helper="$(git config --global credential.helper 2>/dev/null || true)"

    if [ "$helper" = "store" ]; then
        git config --global --unset credential.helper || true
    fi

    printf 'protocol=https\nhost=github.com\nusername=kjwat\n\n' | git credential reject || true
fi

rm -f "$HOME/.git-credentials"

cd "$HOME"
rm -rf "$ROOT"

echo
echo "Burn complete."
