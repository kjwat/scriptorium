#!/bin/sh

# Resolve an operating-system family to one closed set of values.  In
# particular, /etc/os-release is parsed as data and is never sourced.

result=unknown
os=$(uname -s 2>/dev/null) || os=unknown

case "$os" in
    Darwin)
        result=macos
        ;;
    MINGW* | MSYS* | CYGWIN*)
        result=msys2
        ;;
    Linux)
        if [ -r /etc/os-release ]; then
            id=
            id_like=
            id_seen=0
            id_like_seen=0
            valid=1

            while IFS= read -r line || [ -n "$line" ]; do
                case "$line" in
                    '' | \#*)
                        continue
                        ;;
                    *=*)
                        key=${line%%=*}
                        value=${line#*=}
                        ;;
                    *)
                        valid=0
                        continue
                        ;;
                esac

                case "$key" in
                    '' | [!A-Z_]* | *[!A-Z0-9_]*)
                        valid=0
                        continue
                        ;;
                esac

                case "$value" in
                    \"*\")
                        value=${value#\"}
                        value=${value%\"}
                        ;;
                    \'*\')
                        value=${value#\'}
                        value=${value%\'}
                        ;;
                    \"* | \'*)
                        valid=0
                        continue
                        ;;
                    *' '* | *'	'*)
                        valid=0
                        continue
                        ;;
                esac

                case "$key" in
                    ID)
                        if [ "$id_seen" -ne 0 ]; then
                            valid=0
                        else
                            id=$value
                            id_seen=1
                        fi
                        ;;
                    ID_LIKE)
                        if [ "$id_like_seen" -ne 0 ]; then
                            valid=0
                        else
                            id_like=$value
                            id_like_seen=1
                        fi
                        ;;
                esac
            done < /etc/os-release

            if [ "$valid" -eq 1 ]; then
                resolved=
                ambiguous=0

                add_family() {
                    if [ -z "$resolved" ]; then
                        resolved=$1
                    elif [ "$resolved" != "$1" ]; then
                        ambiguous=1
                    fi
                }

                add_token() {
                    case "$1" in
                        void) add_family void ;;
                        debian | ubuntu) add_family debian ;;
                        arch) add_family arch ;;
                        fedora | rhel | centos) add_family fedora ;;
                        alpine) add_family alpine ;;
                        opensuse | opensuse-leap | opensuse-tumbleweed | suse | sles)
                            add_family suse
                            ;;
                    esac
                }

                add_token "$id"

                # Disable pathname expansion before tokenizing ID_LIKE as a set.
                set -f
                for token in $id_like; do
                    add_token "$token"
                done
                set +f

                if [ "$ambiguous" -eq 0 ] && [ -n "$resolved" ]; then
                    result=$resolved
                fi
            fi
        fi
        ;;
    *)
        ;;
esac

printf '%s\n' "$result"
exit 0
