#!/usr/bin/env python3
"""Check portable initialization and existing/fresh daemon defaults."""
import os
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
installer = (root / 'install.sh').read_text()
commands = installer.split('EXPECTED_SIMPLESUITE_COMMANDS=()\n', 1)[1].split(
    'declare -a EXPECTED_SIMPLESUITE_HELPERS=', 1)[0]
service = installer.split('simpleserve_service_mode=', 1)[1].split(
    'SIMPLESUITE_INSTALL_PACKAGES=0', 1)[0]
with tempfile.TemporaryDirectory(prefix='scriptorium-portability-') as tmp:
    directory = Path(tmp)
    present, missing = directory / 'existing-daemon', directory / 'missing-daemon'
    present.write_text('preserved daemon')
    present.chmod(0o755)
    shells = ['bash']
    if os.environ.get('SCRIPTORIUM_TEST_BASH32'):
        shells.append(os.environ['SCRIPTORIUM_TEST_BASH32'])
    for shell in shells:
        subprocess.run([shell, '-n', str(root / 'install.sh')], check=True)
    for host in ('Linux', 'Darwin'):
        # macOS ships Bash 3.2, without mapfile/readarray. Disable the builtin
        # while exercising the actual initialization rather than a replacement.
        script = '''set -euo pipefail
enable -n mapfile 2>/dev/null || :
HOST_OS=$TEST_HOST
scriptorium_suite_programs() { printf '%s\\n' simplewords simplebook; }
EXPECTED_SIMPLESUITE_COMMANDS=()
''' + commands + '''
[[ ${EXPECTED_SIMPLESUITE_COMMANDS[0]} == simplewords ]]
[[ ${EXPECTED_SIMPLESUITE_COMMANDS[1]} == simplebook ]]
[[ " ${EXPECTED_SIMPLESUITE_COMMANDS[*]} " == *" simpleterm "* ]]
'''
        for shell in shells:
            subprocess.run([shell, '-c', script], env=dict(os.environ, TEST_HOST=host), check=True)
    for binary, override, enabled, expected in (
            (present, '', 1, 'preserve'), (missing, '', 1, 'require'),
            (missing, 'preserve', 1, 'preserve'), (missing, '', 0, 'skip')):
        env = dict(os.environ, SIMPLESERVE_DAEMON_BINARY=str(binary),
                   SIMPLESUITE_INSTALL_SIMPLESERVE=str(enabled), EXPECTED_MODE=expected)
        env.pop('SIMPLESUITE_INSTALL_SIMPLESERVE_SYSTEM', None)
        if override: env['SIMPLESUITE_INSTALL_SIMPLESERVE_SYSTEM'] = override
        subprocess.run(['bash', '-euc', 'simpleserve_service_mode=' + service +
                        '\n[[ $simpleserve_service_mode == "$EXPECTED_MODE" ]]'], env=env, check=True)
print('OK macOS-compatible initialization and first-install/preservation service defaults')
