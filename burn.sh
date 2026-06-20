#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

echo
echo "BURN MODE"
echo
echo "This will remove:"
echo "  - ~/scriptorium"
echo "  - ~/writing, including its GitHub connection"
echo "  - ~/simplesuite and ~/src/simplesuite"
echo "  - SimpleSuite binaries in ~/.local/bin"
echo "  - ~/.mutt"
echo "  - ~/.newsboat"
echo "  - ~/.config/calcurse"
echo "  - ~/.config/simplefiles"
echo "  - ~/.config/simplepod"
echo "  - ~/.links"
echo "  - ~/.ssh"
echo "  - ~/.gitconfig"
echo "  - ~/.git-credentials"
echo "  - ~/.config/gh"
echo
printf "Type BURN to continue: "
read ans

[ "$ans" = "BURN" ] || {
    echo "Cancelled."
    exit 1
}

rm -rf "$HOME/writing"
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

rm -rf "$HOME/.ssh"
rm -f "$HOME/.gitconfig"
rm -f "$HOME/.git-credentials"
rm -rf "$HOME/.config/gh"

cd "$HOME"
rm -rf "$ROOT"

echo "Burn complete."
