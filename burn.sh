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

for bin in simplewords simplefiles simpleflac simpleradio simplepod simplevis simplepdf simpleclock simplestats simplever simplegame; do
    rm -f "$HOME/.local/bin/$bin"
done

rm -rf "$HOME/.mutt"
rm -rf "$HOME/.newsboat"
rm -rf "$HOME/.config/calcurse"
rm -rf "$HOME/.config/simplefiles"
rm -rf "$HOME/.config/simplepod"
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
        "kjwat@protonmail.com")
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
    sed -i "/alias stats='simplestats'/d" "$HOME/.bashrc"
    sed -i "/alias ver='simplever'/d" "$HOME/.bashrc"
    sed -i "/alias game='simplegame'/d" "$HOME/.bashrc"
    sed -i "/alias pdf='simplepdf'/d" "$HOME/.bashrc"
fi

# Remove credential helper if Scriptorium enabled it.
if command -v git >/dev/null 2>&1; then
    helper="$(git config --global credential.helper 2>/dev/null || true)"

    if [ "$helper" = "store" ]; then
        git config --global --unset credential.helper || true
    fi
fi

rm -f "$HOME/.git-credentials"

clean_kjwat_credentials

cd "$HOME"
rm -rf "$ROOT"

echo
echo "Burn complete."
