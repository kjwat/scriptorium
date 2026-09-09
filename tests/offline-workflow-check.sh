#!/bin/bash
set -euo pipefail

# Linux integration acceptance test: run the real build and installer with
# no network interfaces/routes, a silent Tailscale CLI, and unreachable Git.
# Only service-manager/reminder activation is stubbed; compilation, payload
# installation, dependency checks and verification use the actual scripts.
repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
suite=${SIMPLESUITE_SOURCE_DIR:-$repo/../simplesuite}
work=$(mktemp -d "${TMPDIR:-/tmp}/scriptorium-offline-workflow.XXXXXX")
cleanup() {
    result=$?
    if [ "$result" -ne 0 ]; then
        for log in "$work/build.log" "$work/install.log"; do
            [ ! -f "$log" ] || tail -50 "$log"
        done
    fi
    rm -rf -- "$work"
}
trap cleanup EXIT HUP INT TERM
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

snapshot() {
    git clone -q --no-hardlinks "$1" "$2"
    python3 - "$1" "$2" <<'PY'
from pathlib import Path
import shutil
import subprocess
import sys
source, target = map(Path, sys.argv[1:])
files = subprocess.check_output(["git", "-C", str(source), "ls-files", "--cached", "--others", "--exclude-standard", "-z"])
for name in files.decode().split("\0"):
    if not name:
        continue
    src, dst = source / name, target / name
    if src.is_file() or src.is_symlink():
        dst.parent.mkdir(parents=True, exist_ok=True)
        if dst.exists() or dst.is_symlink():
            dst.unlink()
        shutil.copy2(src, dst, follow_symlinks=False)
    elif dst.is_file():
        dst.unlink()
PY
    git -C "$2" add -A
    git -C "$2" -c user.name=OfflineTest -c user.email=offline@example.invalid \
        -c core.hooksPath=/dev/null commit -qm 'Offline test snapshot' --allow-empty
}

snapshot "$suite" "$work/simplesuite"
snapshot "$repo" "$work/scriptorium"
git -C "$work/simplesuite" remote set-url origin http://192.0.2.1/unreachable.git
mkdir -p "$work/home" "$work/bin" "$work/etc" "$work/system/run/systemd/system"
# A private /etc prevents even optional installer setup from touching the host.
for file in passwd group nsswitch.conf os-release ld.so.cache; do
    [ ! -r "/etc/$file" ] || cp -L "/etc/$file" "$work/etc/$file"
done
[ ! -d /etc/alternatives ] || cp -a /etc/alternatives "$work/etc/"
for program in systemctl crontab apparmor_parser; do
    cat >"$work/bin/$program" <<'STUB'
#!/bin/sh
printf '%s %s\n' "${0##*/}" "$*" >>"$OFFLINE_ACTIVATION_LOG"
exit 0
STUB
    chmod 755 "$work/bin/$program"
done
cat >"$work/bin/tailscale" <<'STUB'
#!/bin/sh
exec sleep 30
STUB
chmod 755 "$work/bin/tailscale"
cat >"$work/run.sh" <<'RUN'
#!/bin/bash
set -euo pipefail
mount --bind "$OFFLINE_WORK/etc" /etc
export HOME="$OFFLINE_WORK/home"
export GIT_CONFIG_GLOBAL="$HOME/.gitconfig"
export XDG_CONFIG_HOME="$HOME/.config" XDG_DATA_HOME="$HOME/.local/share"
export PATH="$OFFLINE_WORK/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export OFFLINE_ACTIVATION_LOG="$OFFLINE_WORK/activation.log"
export SIMPLESERVE_SYSTEM_TEST_MODE=1 SIMPLESERVE_SYSTEM_ROOT="$OFFLINE_WORK/system"
export SIMPLESERVE_SYSTEM_INIT=systemd SIMPLESUITE_NETWORK_ROLE=client
export SIMPLESUITE_ROLE_FILE="$OFFLINE_WORK/system/etc/simpleserve-role"
export SIMPLESUITE_NONINTERACTIVE=1 SIMPLESUITE_JOBS=4
export SCRIPTORIUM_NONINTERACTIVE=1 SCRIPTORIUM_NETWORK_ROLE=client
export SCRIPTORIUM_INSTALL_TAILSCALE=1 SCRIPTORIUM_TAILSCALE_TEST_MODE=1
export SCRIPTORIUM_TAILSCALE_SYSTEM_ROOT="$OFFLINE_WORK/system"
export SCRIPTORIUM_TAILSCALE_INIT=systemd
export SCRIPTORIUM_GIT_NAME=OfflineTest SCRIPTORIUM_GIT_EMAIL=offline@example.invalid
export SIMPLESUITE_DIR="$OFFLINE_WORK/simplesuite"
export SIMPLESUITE_SYSTEM_BIN_DIR="$OFFLINE_WORK/system/usr/local/bin"
export SIMPLESERVE_DAEMON_BINARY="$OFFLINE_WORK/system/usr/local/sbin/simpleserved"
python3 - <<'PY'
import socket
try:
    socket.create_connection(("192.0.2.1", 443), timeout=0.2)
except OSError:
    print("OK network namespace: remote server unreachable")
else:
    raise AssertionError("test unexpectedly has network access")
PY
cd "$SIMPLESUITE_DIR"
timeout -k 2 180 ./build.sh >"$OFFLINE_WORK/build.log" 2>&1
printf '%s\n' 'OK ./build.sh completed without network access'
python3 tests/simpleserve-offline-check.py
cd "$OFFLINE_WORK/scriptorium"
timeout -k 2 180 ./install.sh >"$OFFLINE_WORK/install.log" 2>&1
grep -q 'building the existing local checkout' "$OFFLINE_WORK/install.log"
grep -q 'preserving enrollment and deferring connection' "$OFFLINE_WORK/install.log"
grep -q 'Done. The Scriptorium is installed.' "$OFFLINE_WORK/install.log"
printf '%s\n' 'OK ./install.sh completed with unreachable Git, Tailscale and remote servers'
. "$SIMPLESUITE_DIR/program-manifest.sh"
while IFS=: read -r short full; do
    for directory in "$HOME/.local/bin" "$SIMPLESUITE_SYSTEM_BIN_DIR"; do
        [ ! -e "$directory/$short" ] && [ ! -L "$directory/$short" ]
    done
done < <(simplesuite_program_aliases Linux 1; printf '%s\n' check:simplecheck trident:simpletrident)
PATH="$SIMPLESUITE_SYSTEM_BIN_DIR:$PATH" \
    bash --noprofile --rcfile "$HOME/.bashrc" -ic \
    '[[ $(type -t words) == alias ]]; [[ $(type -P simplewords) == "$SIMPLESUITE_SYSTEM_BIN_DIR/simplewords" ]]; words --version'
printf '%s\n' 'OK shell aliases launch canonical system binaries with no short-name bin entries'
RUN
if ! OFFLINE_WORK="$work" unshare --user --map-root-user --mount --net \
        bash "$work/run.sh"; then
    tail -50 "$work/build.log" "$work/install.log" 2>/dev/null || true
    exit 1
fi
