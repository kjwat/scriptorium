#!/bin/sh
set -eu

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)

# Exercise the actual dependency-to-package mapper without running the report.
eval "$(awk '
    /^pkg_for_dep\(\)/ { copying=1 }
    /^packages_for_family\(\)/ { exit }
    copying { print }
' "$repo/scripts/checkdeps.sh")"

assert_mapping() {
    family=$1
    expected=$2
    actual=$(pkg_for_dep ntfsfix)
    [ "$actual" = "$expected" ] || {
        echo "ntfs-package-mapping-check: $family maps ntfsfix to $actual, expected $expected" >&2
        exit 1
    }
}

assert_mapping debian ntfs-3g
assert_mapping void ntfs-3g
assert_mapping arch ntfsprogs
assert_mapping fedora ntfsprogs
assert_mapping suse ntfsprogs
assert_mapping alpine ntfs-3g-progs
assert_mapping freebsd fusefs-ntfs

split_rpm_count=$(grep -c \
    'exfatprogs ntfs-3g ntfsprogs wl-clipboard' \
    "$repo/scripts/install-packages.sh")
[ "$split_rpm_count" -eq 3 ] || {
    echo 'ntfs-package-mapping-check: Arch/Fedora/openSUSE transactions need ntfsprogs' >&2
    exit 1
}
grep -q 'ntfs-3g ntfs-3g-progs wl-clipboard' \
    "$repo/scripts/install-packages.sh"
grep -q 'ntfs-3g ntfsprogs wl-clipboard' "$repo/packages/arch.txt"
grep -q 'ntfs-3g ntfs-3g-progs wl-clipboard' "$repo/packages/alpine.txt"

echo 'OK NTFS repair utilities map to each current distro split package'
