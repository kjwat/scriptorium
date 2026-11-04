#!/usr/bin/env python3
"""A complete source fixture must reject stale or missing system programs."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='scriptorium-verify-') as tmp:
    base = Path(tmp)
    fixture, suite = base / 'scriptorium', base / 'suite'
    binary, data = base / 'system/bin', base / 'system/data'
    for directory in (fixture / 'scripts', fixture / 'build', suite / 'build', binary, data):
        directory.mkdir(parents=True)
    for name in ('verify-installed-programs.sh', 'resolve-simpleserve-role.sh'):
        shutil.copy(root / 'scripts' / name, fixture / 'scripts' / name)
    # Keep the fixture independent of a host SimpleSuite installation.
    (suite / 'program-manifest.sh').write_text('''
simplesuite_programs() { printf '%s\\n' simplewords simplebook simplebook-mobi simplechange simplechange-engine; }
simplesuite_desktop_aliases() { printf '%s\\n' term:simpleterm play:simpleplay pdf:simplepdf; }
''')
    (suite / '.gitignore').write_text('build/\n')
    subprocess.run(['git', 'init', '-q', str(suite)], check=True)
    subprocess.run(['git', '-C', str(suite), 'add', '.'], check=True)
    subprocess.run(['git', '-C', str(suite), '-c', 'user.name=Test', '-c',
                    'user.email=test@example.invalid', 'commit', '-qm', 'source'], check=True)
    sha = subprocess.check_output(['git', '-C', str(suite), 'rev-parse', 'HEAD'], text=True).strip()
    for name in ('simplewords', 'simplebook', 'simplebook-mobi', 'simplechange',
                 'simplepdf', 'simpleterm', 'simpleplay', 'simpleplay-core'):
        path = suite / 'build' / name
        path.write_text(f'#!/bin/sh\necho "simplewords {sha}"\n' if name == 'simplewords'
                        else '#!/bin/sh\n# ' + name + '\nexit 0\n')
        path.chmod(0o755)
        shutil.copy(path, binary / name)
    for name in ('simplechange-engine', 'simplebrowse-webkitd', 'simplebrowse-jsdump', 'simplevol-audio', 'uninstall.sh'):
        path = suite / name
        path.write_text('# source ' + name)
        shutil.copy(path, binary / ('simplesuite-uninstall' if name == 'uninstall.sh' else name))
    for name in ('simplecheck', 'simpletrident'):
        (fixture / 'build' / name).write_text('current ' + name)
        shutil.copy(fixture / 'build' / name, binary / name)
    (fixture / 'setup-server.sh').write_text('current bootstrap')
    shutil.copy(fixture / 'setup-server.sh', binary / 'setup-server')
    shutil.copy(suite / 'program-manifest.sh', data / 'program-manifest.sh')
    (data / 'install-manifest').write_text(f'simplesuite_source_sha={sha}\nsimplewords_build_revision={sha}\n')
    env = dict(os.environ, SIMPLESUITE_DIR=str(suite), SIMPLESUITE_SYSTEM_BIN_DIR=str(binary),
               SIMPLESUITE_SYSTEM_DATA_DIR=str(data), SIMPLESUITE_NETWORK_ROLE='none')
    env.pop('SIMPLESUITE_INSTALL_SIMPLESERVE', None)

    def run():
        return subprocess.run(['sh', str(fixture / 'scripts/verify-installed-programs.sh')],
                              env=env, capture_output=True, text=True)

    valid = run()
    assert valid.returncode == 0, valid.stderr
    for name in ('simplepdf', 'simpletrident', 'simpleplay-core', 'setup-server'):
        target = binary / name
        good = target.read_bytes()
        target.write_text('old executable')
        stale = run()
        assert stale.returncode != 0 and name in stale.stderr
        target.unlink()
        missing = run()
        assert missing.returncode != 0 and name in missing.stderr
        target.write_bytes(good)
    (data / 'install-manifest').write_text('simplesuite_source_sha=old\n')
    assert run().returncode != 0
print('OK final verification rejects stale programs, missing engines and obsolete revision records')
