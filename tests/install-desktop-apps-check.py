#!/usr/bin/env python3
"""Exercise install.sh's real standalone-app phase in disposable prefixes."""
import json
import os
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
installer = (root / 'install.sh').read_text()
phase = installer.split('say "Installing SimplePlay and SimpleTerm"\n', 1)[1].split(
    'say "Installing SimpleCheck"', 1)[0]
stub = '''#!/usr/bin/env python3
import json, os, pathlib, sys
app = pathlib.Path(sys.argv[0]).stem.removeprefix('install-')
with open(os.environ['TEST_CALLS'], 'a') as output:
    output.write(json.dumps([app, sys.argv[1:], os.environ[app.upper() + '_NONINTERACTIVE']]) + '\\n')
if os.environ.get('TEST_FAIL') == app:
    sys.exit(17)
programs = [app] if app in ('simpleterm', 'simplepdf') else ['simpleplay-core']
if app == 'simpleplay' and '--headless-only' not in sys.argv:
    assert os.environ['SIMPLEPLAY_HEADLESS_ONLY'] == '0'
    programs.append('simpleplay')
for name in programs:
    target = pathlib.Path(os.environ['SIMPLESUITE_SYSTEM_BIN_DIR']) / name
    target.write_text('#!/bin/sh\\nexit 0\\n')
    target.chmod(0o755)
'''

with tempfile.TemporaryDirectory(prefix='scriptorium-desktop-') as temporary:
    base = Path(temporary)
    suite = base / 'suite with spaces'
    suite.mkdir()
    for app in ('simpleplay', 'simpleterm', 'simplepdf'):
        path = suite / f'install-{app}.sh'
        path.write_text(stub)
        path.chmod(0o755)
    for system in ('Linux', 'FreeBSD', 'Darwin'):
        for unattended in ('0', '1'):
            directory = base / (system + unattended)
            home, binary = directory / 'home', directory / 'system-bin'
            legacy = home / '.local/bin'
            legacy.mkdir(parents=True)
            binary.mkdir()
            expected = ['simpleterm', 'simpleplay-core']
            if system != 'Darwin':
                expected.extend(('simpleplay', 'simplepdf'))
            for program in expected:
                (legacy / program).write_text('old user-local copy')
            calls = directory / 'calls.jsonl'
            env = dict(os.environ, HOME=str(home), SIMPLESUITE_DIR=str(suite),
                       SIMPLESUITE_SYSTEM_BIN_DIR=str(binary), HOST_OS=system,
                       SCRIPTORIUM_NONINTERACTIVE=unattended, TEST_CALLS=str(calls))
            result = subprocess.run(['bash', '-euc', 'warn() { echo "$*" >&2; };\n' + phase],
                                    env=env, capture_output=True, text=True)
            assert result.returncode == 0, result.stderr
            recorded = [json.loads(line) for line in calls.read_text().splitlines()]
            player_args = ['--no-deps', '--headless-only'] if system == 'Darwin' else ['--no-deps']
            expected_calls = [['simpleplay', player_args, unattended]]
            if system != 'Darwin':
                expected_calls.append(['simplepdf', ['--no-deps'], unattended])
            expected_calls.append(['simpleterm', ['--no-deps'], unattended])
            assert recorded == expected_calls, recorded
            assert all((binary / name).is_file() and not (legacy / name).exists() for name in expected)
            # A failed player install must stop the full install and retain old copies.
            calls.unlink()
            (legacy / 'simpleplay-core').write_text('preserve until replacement succeeds')
            result = subprocess.run(['bash', '-euc', 'warn() { echo "$*" >&2; };\n' + phase],
                                    env=env | {'TEST_FAIL': 'simpleplay'}, capture_output=True)
            assert result.returncode == 17
            assert len(calls.read_text().splitlines()) == 1
            assert (legacy / 'simpleplay-core').is_file()
print('OK full installs include SimplePlay, its core and SimpleTerm, propagate unattended mode and stop on failure')
