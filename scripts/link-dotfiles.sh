#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
DOT="$ROOT/dotfiles"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="$HOME/.scriptorium-backups/$STAMP"

backup_path() {
    target="$1"
    [ -e "$target" ] || [ -L "$target" ] || return 0
    mkdir -p "$BACKUP/$(dirname "${target#$HOME/}")"
    mv "$target" "$BACKUP/${target#$HOME/}"
    echo "Backed up $target -> $BACKUP/${target#$HOME/}"
}

link_file() {
    src="$1"
    target="$2"
    [ -e "$src" ] || [ -L "$src" ] || return 0
    mkdir -p "$(dirname "$target")"
    if [ -L "$target" ] && [ "$(readlink "$target")" = "$src" ]; then
        echo "Already linked: $target"
        return 0
    fi
    backup_path "$target"
    ln -s "$src" "$target"
    echo "Linked $target -> $src"
}

link_dir() {
    src="$1"
    target="$2"
    [ -d "$src" ] || return 0
    mkdir -p "$(dirname "$target")"
    if [ -L "$target" ] && [ "$(readlink "$target")" = "$src" ]; then
        echo "Already linked: $target"
        return 0
    fi
    backup_path "$target"
    ln -s "$src" "$target"
    echo "Linked $target -> $src"
}

mkdir -p "$HOME/.config"

link_file "$DOT/mutt/muttrc" "$HOME/.mutt/muttrc"


link_dir "$DOT/calcurse" "$HOME/.config/calcurse"
link_dir "$DOT/links" "$HOME/.links"

link_file "$DOT/simplefiles/config" "$HOME/.config/simplefiles/config"

if [ -d "$BACKUP" ]; then
    echo "Backups saved in $BACKUP"
fi
