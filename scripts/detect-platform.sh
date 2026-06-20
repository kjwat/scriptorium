#!/usr/bin/env bash
set -euo pipefail

os="$(uname -s 2>/dev/null || echo unknown)"
distro="unknown"
family="unknown"

case "$os" in
    Darwin) echo "macos"; exit 0 ;;
    MINGW*|MSYS*|CYGWIN*) echo "msys2"; exit 0 ;;
esac

if [ -r /etc/os-release ]; then
    . /etc/os-release
    distro="${ID:-unknown}"
    like="${ID_LIKE:-}"
    case "$distro $like" in
        *void*) echo "void" ;;
        *debian*|*ubuntu*) echo "debian" ;;
        *arch*) echo "arch" ;;
        *fedora*|*rhel*|*centos*) echo "fedora" ;;
        *alpine*) echo "alpine" ;;
        *opensuse*|*suse*) echo "suse" ;;
        *) echo "$distro" ;;
    esac
else
    echo "unknown"
fi
