#!/usr/bin/env bash
set -euo pipefail

say() { printf '\n==> %s\n' "$*"; }
warn() { printf '\n!! %s\n' "$*" >&2; }

block_begin="# BEGIN SCRIPTORIUM SIMPLEMAIL GMAIL"
block_end="# END SCRIPTORIUM SIMPLEMAIL GMAIL"

strip_block() {
    file=$1
    [ -f "$file" ] || return 0
    tmp="$(mktemp)"
    awk -v b="$block_begin" -v e="$block_end" '
        $0 == b { skip=1; next }
        $0 == e { skip=0; next }
        !skip { print }
    ' "$file" > "$tmp"
    cat "$tmp" > "$file"
    rm -f "$tmp"
}

say "SimpleMail Gmail setup"

printf 'Gmail address: '
read -r gmail_addr

from_addr="$gmail_addr"

printf 'Gmail app password: '
stty -echo
read -r gmail_pass
stty echo
printf '\n'

if [ -z "$gmail_addr" ] || [ -z "$gmail_pass" ]; then
    warn "Missing Gmail address or app password. Nothing written."
    exit 1
fi

mkdir -p "$HOME/.config/simplemail"
mkdir -p "$HOME/.local/share/simplemail/mail"

for box in Inbox Sent Drafts Archive Trash; do
    mkdir -p "$HOME/.local/share/simplemail/mail/$box/cur" \
             "$HOME/.local/share/simplemail/mail/$box/new" \
             "$HOME/.local/share/simplemail/mail/$box/tmp"
done

mb="$HOME/.mbsyncrc"
ms="$HOME/.msmtprc"

touch "$mb" "$ms"
chmod 600 "$mb" "$ms"

strip_block "$mb"
strip_block "$ms"

cat >> "$mb" <<EOF

$block_begin
IMAPAccount gmail
Host imap.gmail.com
Port 993
User $gmail_addr
Pass "$gmail_pass"
SSLType IMAPS
AuthMechs LOGIN

IMAPStore gmail-remote
Account gmail

MaildirStore gmail-local
Path ~/.local/share/simplemail/mail/
Inbox ~/.local/share/simplemail/mail/Inbox
SubFolders Verbatim

Channel gmail-inbox
Far :gmail-remote:INBOX
Near :gmail-local:Inbox
Create Near
Expunge Near
SyncState *

Channel gmail-sent
Far :gmail-remote:"[Gmail]/Sent Mail"
Near :gmail-local:Sent
Create Near
Expunge Near
SyncState *

Channel gmail-drafts
Far :gmail-remote:"[Gmail]/Drafts"
Near :gmail-local:Drafts
Create Near
Expunge Near
SyncState *

Channel gmail-trash
Far :gmail-remote:"[Gmail]/Trash"
Near :gmail-local:Trash
Create Near
Expunge Near
SyncState *

Group gmail
Channel gmail-inbox
Channel gmail-sent
Channel gmail-drafts
Channel gmail-trash
$block_end
EOF

cat >> "$ms" <<EOF

$block_begin
account gmail
host smtp.gmail.com
port 587
auth on
tls on
tls_starttls on
user $gmail_addr
password $gmail_pass
from $from_addr

account default : gmail
$block_end
EOF

cat > "$HOME/.config/simplemail/config" <<EOF
sync_cmd=mbsync gmail
send_cmd=msmtp -a gmail -t
from=$from_addr
EOF

chmod 600 "$HOME/.config/simplemail/config"

say "SimpleMail Gmail config written."
printf '%s\n' \
    "Test pull: mbsync gmail" \
    "Test send: printf 'To: $gmail_addr\nSubject: SimpleMail test\n\nhello\n' | msmtp -a gmail -t" \
    "In SimpleMail: press p to pull; send uses msmtp account 'gmail'."
