#!/usr/bin/env bash
set -euo pipefail

storage_mode=${SIMPLEMAIL_STORAGE_MODE:-sync}
if [ -z "${SIMPLEMAIL_STORAGE_MODE-}" ] && [ -z "${1-}" ] &&
   [ -f "$HOME/.config/simplemail/config" ] &&
   awk '/^[[:space:]]*sync_cmd[[:space:]]*=/ && index($0, "simplemail-fetch") && index($0, "--remove-server-copy") { found=1 } END { exit !found }' "$HOME/.config/simplemail/config"; then
    storage_mode=local-only
fi
case "${1-}" in
    --local-only) storage_mode=local-only ;;
    --sync) storage_mode=sync ;;
    '') ;;
    *) printf 'Usage: %s [--local-only|--sync]\n' "$0" >&2; exit 2 ;;
esac
case "$storage_mode" in
    sync)
        sync_policy='Sync Full'
        expunge_policy='Expunge Near'
        sync_command='mbsync gmail'
        fetch_on_start=0
        check_interval=0
        ;;
    local-only)
        sync_policy='Sync None'
        expunge_policy='Expunge None'
        sync_command='simplemail-fetch --account gmail --remove-server-copy'
        fetch_on_start=1
        check_interval=60
        if ! command -v simplemail-fetch >/dev/null 2>&1; then
            printf 'Install the current SimpleSuite (simplemail-fetch is required).\n' >&2
            exit 1
        fi
        ;;
    *) printf 'SIMPLEMAIL_STORAGE_MODE must be sync or local-only.\n' >&2; exit 2 ;;
esac

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
if [ "$storage_mode" = local-only ]; then
    printf '%s\n' 'Local delivery: saved messages will be permanently removed from Gmail.'
fi

printf 'Gmail address: '
read -r gmail_addr

from_addr="$gmail_addr"
maildir="$HOME/.local/share/simplemail/mail"

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
mkdir -p "$maildir"

for box in Inbox Sent Drafts Archive Trash; do
    mkdir -p "$maildir/$box/cur" \
             "$maildir/$box/new" \
             "$maildir/$box/tmp"
done

mb="$HOME/.mbsyncrc"
mb_xdg="$HOME/.config/isyncrc"
ms="$HOME/.msmtprc"

mkdir -p "$HOME/.config"

touch "$mb" "$ms"
chmod 600 "$mb" "$ms"
rm -f "$mb_xdg"
ln -s "$mb" "$mb_xdg"

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
Path $maildir/
Inbox $maildir/Inbox
SubFolders Verbatim

Channel gmail-inbox
Far :gmail-remote:INBOX
Near :gmail-local:Inbox
Create Near
$sync_policy
$expunge_policy
SyncState *

Channel gmail-sent
Far :gmail-remote:"[Gmail]/Sent Mail"
Near :gmail-local:Sent
Create Near
$sync_policy
$expunge_policy
SyncState *

Channel gmail-drafts
Far :gmail-remote:"[Gmail]/Drafts"
Near :gmail-local:Drafts
Create Near
$sync_policy
$expunge_policy
SyncState *

Channel gmail-trash
Far :gmail-remote:"[Gmail]/Trash"
Near :gmail-local:Trash
Create Near
$sync_policy
$expunge_policy
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
maildir=$maildir
sync_cmd=$sync_command
fetch_on_start=$fetch_on_start
check_interval=$check_interval
send_cmd=msmtp -a gmail -t
from=$from_addr
EOF

chmod 600 "$HOME/.config/simplemail/config"

say "SimpleMail Gmail config written."
printf '%s\n' \
    "Mail delivery command: $sync_command" \
    "Test send: printf 'To: $gmail_addr\nSubject: SimpleMail test\n\nhello\n' | msmtp -a gmail -t" \
    "In SimpleMail: press p to check mail; send uses msmtp account 'gmail'."
if [ "$storage_mode" = local-only ]; then
    printf '%s\n' \
        'SimpleMail downloads on launch and every 60 seconds while open.' \
        'Inbox, Sent, Drafts, Archive, Spam and Trash stay in your local Maildir.' \
        'Legacy mbsync channels are disabled so they cannot upload your local mail.'
fi
