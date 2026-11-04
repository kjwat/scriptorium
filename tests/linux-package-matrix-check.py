#!/usr/bin/env python3
"""Exercise each real Linux package transaction and provider choice safely."""
import json
import os
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'scripts/install-packages.sh').read_text()
phase = source.split('\nsimplenet_packages=\n', 1)[1].split(
    '\nconfigure_homebrew_pkgconfig\nif ! dependencies_already_present;', 1)[0]
header = '''set -eu
family=$TEST_FAMILY
ROOT=$TEST_ROOT
network_role=none
install_simpleserve=0
simpleserve_packages=
pacman_confirmation=--noconfirm
have_cmd() { command -v "$1" >/dev/null 2>&1; }
have_calibre() { [ "$TEST_CALIBRE" = 1 ]; }
have_pkgconfig() { [ "$1" != libsidplayfp ] || [ "$TEST_SID" = 1 ]; }
check_repository_configuration() { :; }
as_root() { "$@"; }
run_package_command() { shift; "$@"; }
simplenet_packages=
'''
stub = '''#!/usr/bin/python3
import json, os
from pathlib import Path
import sys
name = Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ['TEST_CALLS'], 'a') as output:
    output.write(json.dumps([name, args]) + '\\n')
if name == 'uname': print('Linux')
elif name == 'rpm': sys.exit(0 if os.environ['TEST_FULL_FFMPEG'] == '1' else 1)
elif name == 'dpkg-query':
    if os.environ['TEST_JACK2'] == '1': print('installed', end='')
    else: sys.exit(1)
elif name == 'pacman' and args[0] in ('-Qq', '-Si'):
    sys.exit(0 if args[1] == 'jack2' and os.environ['TEST_JACK2'] == '1' else 1)
elif name == 'apk' and args[0] == 'search':
    if os.environ['TEST_CALIBRE_APK'] == '1': print('calibre-9.16.0-r0')
elif name == 'debconf-set-selections': sys.stdin.read()
'''

with tempfile.TemporaryDirectory(prefix='scriptorium-linux-matrix-') as tmp:
    directory = Path(tmp)
    commands = directory / 'bin'
    commands.mkdir()
    scripts = directory / 'scripts'
    scripts.mkdir()
    for name in ('apt-get', 'apk', 'dnf', 'zypper', 'pacman', 'xbps-install',
                 'rpm', 'uname', 'dpkg-query', 'debconf-set-selections'):
        p = commands / name
        p.write_text(stub)
        p.chmod(0o755)
    builder = scripts / 'install-alpine-source-deps.sh'
    builder.write_text('#!/bin/sh\nprintf built > "$TEST_BUILT"\n')
    builder.chmod(0o755)

    def run(family, **options):
        calls, built = directory / 'calls.jsonl', directory / 'built'
        calls.unlink(missing_ok=True)
        built.unlink(missing_ok=True)
        env = dict(os.environ, PATH=str(commands) + ':' + os.environ['PATH'],
                   TEST_FAMILY=family, TEST_ROOT=str(directory), TEST_CALLS=str(calls),
                   TEST_BUILT=str(built), TEST_CALIBRE='0', TEST_SID='0',
                   TEST_CALIBRE_APK='0', TEST_FULL_FFMPEG='0', TEST_JACK2='0')
        env.update(options)
        result = subprocess.run(['sh', '-c', header + phase], env=env,
                                capture_output=True, text=True, timeout=10)
        assert result.returncode == 0, (family, result.stderr)
        return [json.loads(line) for line in calls.read_text().splitlines()], built.exists()

    for family, manager in (('debian', 'apt-get'), ('arch', 'pacman'), ('fedora', 'dnf'),
                            ('alpine', 'apk'), ('void', 'xbps-install'), ('suse', 'zypper')):
        calls, built = run(family)
        transactions = [args for name, args in calls if name == manager and
                        args[0] in ('install', 'add', '-Syu', '-Sy')]
        args = transactions[-1]
        assert any('evince' in a for a in args), family
        if family == 'fedora': assert 'ffmpeg-free-devel' in args and 'ffmpeg-devel' not in args
        if family == 'suse': assert 'pkgconfig(sdl2)' in args and 'libSDL2-devel' not in args
        if family == 'arch':
            assert 'glib2-devel' in args and '--noconfirm' in args and 'pipewire-jack' in args
        if family == 'debian': assert '--no-upgrade' in args and '--no-remove' in args
        if family == 'alpine':
            assert built and 'calibre' not in args
            assert not any('testing' in a or 'edge/' in a for a in args)
        print('OK', family, 'package transaction')

    calls, built = run('fedora', TEST_FULL_FFMPEG='1')
    assert any(name == 'dnf' and 'ffmpeg-devel' in args and 'ffmpeg-free-devel' not in args
               for name, args in calls)
    calls, built = run('debian', TEST_JACK2='1')
    assert any(name == 'apt-get' and 'libjack-jackd2-dev' in args for name, args in calls)
    calls, built = run('arch', TEST_JACK2='1')
    assert all('pipewire-jack' not in args for name, args in calls
               if name == 'pacman' and args[0] == '-Syu')
    calls, built = run('alpine', TEST_CALIBRE='1', TEST_SID='1')
    assert not built
    calls, built = run('alpine', TEST_CALIBRE_APK='1', TEST_SID='1')
    assert any(name == 'apk' and 'calibre' in args for name, args in calls)
print('OK existing FFmpeg/JACK providers and Alpine source-build selection')
