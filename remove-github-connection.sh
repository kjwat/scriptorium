#!/usr/bin/env bash
set -u

# Remove GitHub authentication and identity from the current Linux account
# without deleting repositories, Scriptorium, SimpleSuite, or writing files.

repos=(
    "$HOME/writing"
    "$HOME/scriptorium"
    "$HOME/simplesuite"
)

say() {
    printf '%s\n' "$1"
}

unset_git_keys() {
    local scope="$1"
    shift
    local args=("$@")

    git config "${args[@]}" --unset-all user.name 2>/dev/null || true
    git config "${args[@]}" --unset-all user.email 2>/dev/null || true
    git config "${args[@]}" --unset-all github.user 2>/dev/null || true
    git config "${args[@]}" --unset-all credential.username 2>/dev/null || true
    git config "${args[@]}" --unset-all credential.helper 2>/dev/null || true
    git config "${args[@]}" --unset-all http.https://github.com/.extraheader 2>/dev/null || true
    git config "${args[@]}" --unset-all http.https://gist.github.com/.extraheader 2>/dev/null || true
}

scrub_credential_file() {
    local file="$1"
    local tmp

    [ -f "$file" ] || return 0
    tmp="$(mktemp)"

    # Preserve credentials for unrelated services; remove only GitHub entries.
    grep -vE 'github\.com|gist\.github\.com' "$file" >"$tmp" || true

    if [ -s "$tmp" ]; then
        chmod --reference="$file" "$tmp" 2>/dev/null || chmod 600 "$tmp"
        mv "$tmp" "$file"
    else
        rm -f "$tmp" "$file"
    fi
}

scrub_remote() {
    local repo="$1"
    local remote url clean

    [ -d "$repo/.git" ] || return 0

    while IFS= read -r remote; do
        [ -n "$remote" ] || continue
        url="$(git -C "$repo" remote get-url "$remote" 2>/dev/null || true)"

        # Strip an embedded HTTPS username, password, or token while retaining
        # the ordinary unauthenticated GitHub remote address.
        clean="$(printf '%s' "$url" | sed -E \
            's#^https://[^/@]+@github\.com/#https://github.com/#;
             s#^https://[^/@]+@gist\.github\.com/#https://gist.github.com/#')"

        if [ -n "$url" ] && [ "$url" != "$clean" ]; then
            git -C "$repo" remote set-url "$remote" "$clean"
        fi
    done < <(git -C "$repo" remote 2>/dev/null || true)

    unset_git_keys "local" -C "$repo" --local
}

say "Removing GitHub authentication from this account..."

# Ask any configured Git credential helper to erase saved GitHub credentials
# before removing the helper configuration itself.
for host in github.com gist.github.com; do
    printf 'protocol=https\nhost=%s\n\n' "$host" | git credential reject 2>/dev/null || true
done

git credential-cache exit 2>/dev/null || true

# Log out GitHub CLI sessions, then remove any remaining GitHub CLI auth files.
if command -v gh >/dev/null 2>&1; then
    gh auth logout --hostname github.com 2>/dev/null || true
fi
rm -rf "$HOME/.config/gh"

# Remove GitHub entries from common plaintext credential stores.
scrub_credential_file "$HOME/.git-credentials"
scrub_credential_file "$HOME/.config/git/credentials"

# Remove GitHub credentials from libsecret/keyring when available.
if command -v secret-tool >/dev/null 2>&1; then
    secret-tool clear protocol https host github.com 2>/dev/null || true
    secret-tool clear protocol https host gist.github.com 2>/dev/null || true
    secret-tool clear server github.com 2>/dev/null || true
    secret-tool clear server gist.github.com 2>/dev/null || true
fi

# Remove global Git identity and GitHub-specific authentication settings.
unset_git_keys "global" --global

# Remove the same settings from the three Scriptorium repositories and scrub
# any token accidentally embedded in their remote URLs.
for repo in "${repos[@]}"; do
    scrub_remote "$repo"
done

# Remove GitHub host fingerprints. These are not credentials, but deleting them
# leaves no GitHub-specific SSH host record in this account.
if command -v ssh-keygen >/dev/null 2>&1; then
    ssh-keygen -R github.com -f "$HOME/.ssh/known_hosts" >/dev/null 2>&1 || true
    ssh-keygen -R ssh.github.com -f "$HOME/.ssh/known_hosts" >/dev/null 2>&1 || true
fi

# Clear token variables when the script is sourced. An executed script cannot
# alter its parent shell, so close the terminal afterward if any were exported.
unset GITHUB_TOKEN GH_TOKEN GITHUB_ENTERPRISE_TOKEN GH_ENTERPRISE_TOKEN 2>/dev/null || true

say "GitHub connection removed."
say "Repositories and files were left intact."
say "Close this terminal to clear any GitHub token inherited by the shell."
