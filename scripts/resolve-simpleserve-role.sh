#!/bin/sh
# Shared role resolution for standalone Scriptorium component scripts.
# Enabling SimpleServe never implies permission to publish shares.

scriptorium_simpleserve_role_file_path()
{
    if [ "${SCRIPTORIUM_SIMPLESERVE_ROLE_FILE+x}" = x ]; then
        role_path=$SCRIPTORIUM_SIMPLESERVE_ROLE_FILE
        role_name=SCRIPTORIUM_SIMPLESERVE_ROLE_FILE
    elif [ "${SIMPLESUITE_ROLE_FILE+x}" = x ]; then
        role_path=$SIMPLESUITE_ROLE_FILE
        role_name=SIMPLESUITE_ROLE_FILE
    else
        case "${SIMPLESERVE_SYSTEM_ROOT:-}" in
            '' | /*)
                printf '%s/etc/simpleserve-role\n' \
                    "${SIMPLESERVE_SYSTEM_ROOT:-}"
                return
                ;;
            *)
                echo "SIMPLESERVE_SYSTEM_ROOT must be an absolute path." >&2
                return 2
                ;;
        esac
    fi

    if [ -z "$role_path" ]; then
        echo "$role_name must not be empty." >&2
        return 2
    fi
    case "$role_path" in
        /*) printf '%s\n' "$role_path" ;;
        *)
            echo "$role_name must be an absolute path." >&2
            return 2
            ;;
    esac
}

scriptorium_read_simpleserve_role()
{
    role_path=$(scriptorium_simpleserve_role_file_path) || return $?
    [ -e "$role_path" ] || return 1
    if [ ! -r "$role_path" ]; then
        echo "Cannot read the existing SimpleServe role: $role_path" >&2
        return 2
    fi
    configured_role=$(tr -d '[:space:]' <"$role_path")
    case "$configured_role" in
        client | server) printf '%s\n' "$configured_role" ;;
        *)
            echo "$role_path must contain exactly client or server." >&2
            return 2
            ;;
    esac
}

scriptorium_resolve_simpleserve_role()
{
    if [ "${SIMPLESUITE_NETWORK_ROLE+x}" = x ]; then
        requested_role=$SIMPLESUITE_NETWORK_ROLE
        case "$requested_role" in
            none) expected_install=0 ;;
            client | server) expected_install=1 ;;
            *)
                echo "SIMPLESUITE_NETWORK_ROLE must be none, client, or server." >&2
                return 2
                ;;
        esac
        if [ "${SIMPLESUITE_INSTALL_SIMPLESERVE+x}" = x ] &&
           [ "$SIMPLESUITE_INSTALL_SIMPLESERVE" != "$expected_install" ]; then
            echo "SIMPLESUITE_NETWORK_ROLE conflicts with SIMPLESUITE_INSTALL_SIMPLESERVE." >&2
            return 2
        fi
        printf '%s\n' "$requested_role"
        return
    fi

    install_setting=${SIMPLESUITE_INSTALL_SIMPLESERVE:-1}
    case "$install_setting" in
        0)
            printf '%s\n' none
            return
            ;;
        1) ;;
        *)
            echo "SIMPLESUITE_INSTALL_SIMPLESERVE must be 0 or 1." >&2
            return 2
            ;;
    esac

    if existing_role=$(scriptorium_read_simpleserve_role); then
        printf '%s\n' "$existing_role"
        return
    else
        existing_status=$?
    fi
    case "$existing_status" in
        1) printf '%s\n' client ;;
        *) return "$existing_status" ;;
    esac
}
