#!/usr/bin/env python3
"""Run the real self-refresh bootstrap against an upstream that changes it."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]


def git(directory, *args):
    return subprocess.check_output(['git', '-C', str(directory), *args],
                                   text=True, stderr=subprocess.DEVNULL).strip()


with tempfile.TemporaryDirectory(prefix='scriptorium-refresh-') as tmp:
    base = Path(tmp)
    origin, source, checkout = base / 'origin.git', base / 'source', base / 'checkout with spaces'
    subprocess.run(['git', 'init', '-q', '--bare', str(origin)], check=True)
    subprocess.run(['git', 'init', '-q', '-b', 'main', str(source)], check=True)
    git(source, 'config', 'user.name', 'Installer test')
    git(source, 'config', 'user.email', 'installer@example.invalid')
    (source / 'scripts').mkdir()
    for name in ('refresh-scriptorium.sh', 'bounded-command.sh'):
        shutil.copy(root / 'scripts' / name, source / 'scripts' / name)
    # Extract the actual entrypoint, so deleting/bypassing its call breaks this test.
    installer = (root / 'install.sh').read_text()
    bootstrap = installer.split('ROOT="$(CDPATH=', 1)[1].split('HOST_OS=', 1)[0]
    bootstrap = '#!/bin/bash\nset -eu\nROOT="$(CDPATH=' + bootstrap
    (source / 'install.sh').write_text(bootstrap + 'echo old > "$TEST_RESULT"\n')
    git(source, 'add', '.')
    git(source, 'commit', '-qm', 'old installer')
    old = git(source, 'rev-parse', 'HEAD')
    git(source, 'remote', 'add', 'origin', str(origin))
    git(source, 'push', '-qu', 'origin', 'main')
    subprocess.run(['git', 'clone', '-q', '-b', 'main', str(origin), str(checkout)], check=True)
    (source / 'install.sh').write_text(bootstrap + 'echo new > "$TEST_RESULT"\n')
    git(source, 'add', '.')
    git(source, 'commit', '-qm', 'new installer')
    git(source, 'push', '-q')
    current = git(source, 'rev-parse', 'HEAD')
    result = base / 'result'
    env = dict(os.environ, TEST_RESULT=str(result))
    for key in ('SCRIPTORIUM_OFFLINE', 'SCRIPTORIUM_REFRESHED_SHA'):
        env.pop(key, None)

    def run(extra=None):
        result.unlink(missing_ok=True)
        return subprocess.run(['bash', str(checkout / 'install.sh')],
                              env=env | (extra or {}), capture_output=True, text=True, timeout=40)

    updated = run()
    assert updated.returncode == 0, updated.stderr
    assert result.read_text().strip() == 'new', updated.stdout
    assert git(checkout, 'rev-parse', 'HEAD') == current
    assert 'Restarting the updated' in updated.stdout

    git(checkout, 'reset', '--hard', old)
    (checkout / 'local-notes').write_text('preserve me')
    dirty = run()
    assert dirty.returncode != 0 and not result.exists()
    assert (checkout / 'local-notes').read_text() == 'preserve me'
    (checkout / 'local-notes').unlink()

    git(checkout, 'remote', 'set-url', 'origin', str(base / 'unavailable'))
    failed = run()
    assert failed.returncode != 0 and not result.exists()
    assert 'Cannot refresh Scriptorium' in failed.stderr
    cached = run({'SCRIPTORIUM_OFFLINE': '1'})
    assert cached.returncode == 0 and result.read_text().strip() == 'old'
    invalid = run({'SCRIPTORIUM_OFFLINE': 'wrong'})
    assert invalid.returncode != 0 and not result.exists()

print('OK installer updates and restarts before work; dirty/offline failures preserve local state')
