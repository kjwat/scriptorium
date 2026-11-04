#!/bin/sh

refresh_scriptorium() {
    case ${SCRIPTORIUM_OFFLINE:-0} in
        0) ;;
        1)
            printf 'Offline installation requested; using cached Scriptorium source.\n'
            return 0
            ;;
        *) printf 'SCRIPTORIUM_OFFLINE must be 0 or 1.\n' >&2; exit 2 ;;
    esac

    if ! command -v git >/dev/null 2>&1; then
        printf 'Git is not installed yet; installer refresh will follow package bootstrap.\n'
        return 0
    fi
    # Source archives are also used by image builds. Never update a parent repo.
    if [ ! -e "$ROOT/.git" ]; then
        printf 'Scriptorium source archive; no Git checkout to refresh.\n'
        return 0
    fi
    refresh_before=$(git -C "$ROOT" rev-parse --verify HEAD) || exit 1
    [ "${SCRIPTORIUM_REFRESHED_SHA:-}" != "$refresh_before" ] || return 0
    refresh_remote=$(git -C "$ROOT" config --get "branch.$(git -C "$ROOT" symbolic-ref --short HEAD).remote") || {
        printf 'Scriptorium must be on a branch tracking its upstream before installation.\n' >&2
        exit 1
    }
    printf 'Refreshing Scriptorium installation instructions from %s...\n' "$refresh_remote"
    if ! scriptorium_bounded 30 env GIT_TERMINAL_PROMPT=0 \
        GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes -o ConnectTimeout=5 -o ConnectionAttempts=1}" \
        git -C "$ROOT" -c http.lowSpeedLimit=1 -c http.lowSpeedTime=5 fetch "$refresh_remote"; then
        printf '%s\n' 'Cannot refresh Scriptorium; installation stopped before changing the machine.' \
            'For an intentional cached installation, set SCRIPTORIUM_OFFLINE=1.' >&2
        exit 1
    fi
    refresh_upstream=$(git -C "$ROOT" rev-parse --verify '@{upstream}') || exit 1
    if [ "$refresh_before" != "$refresh_upstream" ]; then
        if [ -n "$(git -C "$ROOT" status --porcelain --untracked-files=normal)" ]; then
            printf 'Scriptorium has local changes; preserve or commit them before updating %s.\n' "$ROOT" >&2
            exit 1
        fi
        if ! git -C "$ROOT" merge --ff-only '@{upstream}' ||
           [ "$(git -C "$ROOT" rev-parse HEAD)" != "$refresh_upstream" ]; then
            printf 'Scriptorium cannot match upstream by fast-forward; resolve the local branch first.\n' >&2
            exit 1
        fi
        printf 'Restarting the updated Scriptorium installer (%s).\n' "$refresh_upstream"
        SCRIPTORIUM_REFRESHED_SHA=$refresh_upstream
        export SCRIPTORIUM_REFRESHED_SHA
        # The main installer keeps a supplied key in a shell variable until the
        # Tailscale phase. Carry it across this bootstrap restart as well.
        if [ -n "${TAILSCALE_AUTH_KEY_VALUE:-}" ]; then
            TAILSCALE_AUTH_KEY=$TAILSCALE_AUTH_KEY_VALUE
            export TAILSCALE_AUTH_KEY
        fi
        exec bash "$ROOT/install.sh" "$@"
    fi
    SCRIPTORIUM_REFRESHED_SHA=$refresh_before
    export SCRIPTORIUM_REFRESHED_SHA
    printf 'Scriptorium upstream revision: %s\n' "$refresh_before"
    if [ -n "$(git -C "$ROOT" status --porcelain --untracked-files=normal)" ]; then
        printf 'Preserving local installer changes in %s.\n' "$ROOT"
    fi
}
