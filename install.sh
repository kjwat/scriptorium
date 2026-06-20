#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

say() { printf '\n==> %s\n' "$*"; }
warn() { printf '\n!! %s\n' "$*" >&2; }

say "Scriptorium installer"

if ! git config --global user.name >/dev/null 2>&1; then
    printf "Enter your Git name: "
    read -r git_name
    git config --global user.name "$git_name"
fi

if ! git config --global user.email >/dev/null 2>&1; then
    printf "Enter your Git email: "
    read -r git_email
    git config --global user.email "$git_email"
fi

say "Configuring GitHub credentials"
git config --global credential.helper store

printf "Enter your GitHub username: "
read -r github_user

printf "Paste your GitHub PAT: "
stty -echo
read -r github_pat
stty echo
printf '\n'

if [ -n "$github_user" ] && [ -n "$github_pat" ]; then
    printf 'protocol=https\nhost=github.com\nusername=%s\npassword=%s\n\n' "$github_user" "$github_pat" | git credential approve
    chmod 600 "$HOME/.git-credentials" 2>/dev/null || true
fi


say "Configuring Mutt"

printf "Do you want to configure Gmail for Mutt? [y/N] "
read -r setup_gmail

case "$setup_gmail" in
    y|Y|yes|YES)

        mkdir -p "$HOME/.mutt"

        printf "Gmail address: "
        read -r gmail_addr

        printf "Gmail app password: "
        stty -echo
        read -r gmail_pass
        stty echo
        printf '\n'

        cat > "$HOME/.mutt/account.local" <<EOF
set imap_user="$gmail_addr"
set smtp_url="smtp://$gmail_addr@smtp.gmail.com:587/"
set smtp_pass="$gmail_pass"
set folder="imaps://imap.gmail.com/"
set spoolfile="+INBOX"
EOF

        chmod 600 "$HOME/.mutt/account.local"
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
ALIASES

export PATH="$HOME/.local/bin:$PATH"
hash -r

say "Installing package dependencies"
"$ROOT/scripts/install-packages.sh"

say "Installing SimpleSuite"
"$ROOT/scripts/install-simplesuite.sh"

say "Linking dotfiles"
"$ROOT/scripts/link-dotfiles.sh"

say "Creating standard directories"
mkdir -p "$HOME/Downloads" "$HOME/Music" "$HOME/Podcasts"

say "Verifying commands"
for cmd in simplewords simplefiles simplever simpleflac simpleradio simplepod simplepdf simplestats simpleclock simplegame simplevis mutt calcurse links git mpv; do
    command -v "$cmd" >/dev/null 2>&1 || {
        warn "$cmd was installed but is not available on PATH"
        exit 1
    }
done

say "Done. The Scriptorium is installed."
exec bash -l
