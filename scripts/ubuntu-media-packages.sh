#!/bin/sh
# Print the Debian-family PDF SDK and any Ubuntu release-specific runtimes.
# Parse os-release as data; an optional path supports isolated installer tests.
set -eu
release=${1:-/etc/os-release}
if [ -r "$release" ] && awk -F= '
    { value = substr($0, index($0, "=") + 1); gsub(/^[\047"]|[\047"]$/, "", value) }
    $1 == "ID" { id = value }
    $1 == "VERSION_ID" { version = value }
    $1 == "UBUNTU_CODENAME" { codename = value }
    END { exit !((id == "ubuntu" && version == "26.04") || codename == "resolute") }
' "$release"; then
    printf '%s\n' libevince-gtk3-dev libevdocument3-4t64 libevview3-3t64 \
        libavformat62 libavcodec62 libavutil60 libavfilter11 libswscale9 libswresample6
else
    printf '%s\n' libevince-dev
fi
