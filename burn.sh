#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

clean_kjwat_credentials() {
    # Remove only credential-file lines that mention kjwat/github.
    # Do not delete Tommy's whole ~/.git-credentials.
    if [ -f "$HOME/.git-credentials" ]; then
        tmp="$(mktemp)"
        grep -vE 'github\.com.*kjwat|kjwat.*github\.com' "$HOME/.git-credentials" > "$tmp" || true
        mv "$tmp" "$HOME/.git-credentials"
        chmod 600 "$HOME/.git-credentials"
        echo "Cleaned kjwat entries from ~/.git-credentials"
    fi

    # Ask Git's credential helper to forget kjwat/github entries if it can.
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
echo "This will remove:"
echo "  - Scriptorium repo at $ROOT"
echo "  - SimpleSuite clone/build trees"
echo "  - SimpleSuite binaries in ~/.local/bin"
echo "  - Scriptorium-installed dotfiles/configs"
echo "  - ~/writing, if present"
echo "  - kjwat GitHub credential traces only"
echo
echo "This will NOT remove:"
echo "  - ~/.ssh"
echo "  - ~/.gitconfig"
echo "  - ~/.config/gh"
echo "  - unrelated Git credentials"
echo "  - other users' or other projects' Git setup"
echo
printf "Type BURN to continue: "
read ans

[ "$ans" = "BURN" ] || {
    echo "Cancelled."
    exit 1
}

# Burn writing surgically if the helper exists; otherwise remove ~/writing.
if [ -x "$ROOT/burn-writing.sh" ]; then
    WRITING_DIR="${WRITING_DIR:-$HOME/writing}" "$ROOT/burn-writing.sh" <<'BURNINPUT' || true
BURN-WRITING
BURNINPUT
else
    rm -rf "$HOME/writing"
fi

# Remove SimpleSuite clones/build trees.
rm -rf "$HOME/simplesuite" "$HOME/src/simplesuite"

# Remove SimpleSuite installed binaries.
for bin in simplewords simplefiles simpleflac simpleradio simplepod simplevis simplepdf simpleclock simplestats simplever simplegame; do
    rm -f "$HOME/.local/bin/$bin"
done

# Remove Scriptorium dotfiles/configs. These are the things Scriptorium itself installs.
rm -rf "$HOME/.mutt"
rm -rf "$HOME/.newsboat"
rm -rf "$HOME/.config/calcurse"
rm -rf "$HOME/.config/simplefiles"
rm -rf "$HOME/.config/simplepod"
rm -rf "$HOME/.links"
rm -rf "$HOME/.cache/simplefiles"
rm -rf "$HOME/.local/share/simplefiles"

# Remove only KJWat-installed Git identity.
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

# Remove Scriptorium PATH additions.
if [ -f "$HOME/.bashrc" ]; then
    sed -i '/# Scriptorium user binaries/d' "$HOME/.bashrc"
    sed -i '/export PATH="\$HOME\/.local\/bin:\$PATH"/d' "$HOME/.bashrc"
fi

# Remove only kjwat GitHub credential traces.
clean_kjwat_credentials

# Remove the Scriptorium repo itself last.
cd "$HOME"
rm -rf "$ROOT"

echo
echo "Burn complete."
