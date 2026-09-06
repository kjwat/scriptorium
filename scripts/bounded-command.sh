# Bound optional network/daemon calls, including older installed CLI versions.
scriptorium_bounded() (
    scriptorium_limit=$1
    shift
    if command -v timeout >/dev/null 2>&1; then
        exec timeout -k 1 "$scriptorium_limit" "$@"
    elif command -v gtimeout >/dev/null 2>&1; then
        exec gtimeout -k 1 "$scriptorium_limit" "$@"
    fi
    "$@" &
    scriptorium_child=$!
    (
        sleep "$scriptorium_limit" &
        scriptorium_sleep=$!
        trap 'kill "$scriptorium_sleep" 2>/dev/null || :; exit 0' TERM INT HUP
        wait "$scriptorium_sleep" || exit 0
        kill -TERM "$scriptorium_child" 2>/dev/null || exit 0
        sleep 1 &
        scriptorium_sleep=$!
        wait "$scriptorium_sleep" || exit 0
        kill -KILL "$scriptorium_child" 2>/dev/null || :
    ) &
    scriptorium_timer=$!
    scriptorium_result=0
    wait "$scriptorium_child" || scriptorium_result=$?
    kill "$scriptorium_timer" 2>/dev/null || :
    wait "$scriptorium_timer" 2>/dev/null || :
    return "$scriptorium_result"
)
