#!/usr/bin/env python3
"""Exercise the real dashboard against disposable local Git remotes."""
import fcntl
import os
from pathlib import Path
import pty
import re
import select
import struct
import subprocess
import sys
import tempfile
import termios
import time

binary = Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix='simplecheck-repositories-') as temporary:
    root = Path(temporary)
    home = root / 'home'
    home.mkdir()
    env = dict(os.environ, HOME=str(home), TERM='xterm-256color',
               GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1',
               GIT_TERMINAL_PROMPT='0')

    def git(path, *args):
        return subprocess.check_output(['git', '-C', str(path), *args], env=env,
                                       stderr=subprocess.PIPE).decode().strip()

    heads = {}
    for name in ('writing', 'scriptorium', 'simplesuite', 'website', 'simplewm'):
        remote = root / (name + '.git')
        remote.mkdir()
        git(remote, 'init', '--bare', '--initial-branch=main')
        git(home, 'clone', str(remote), name)
        repo = home / name
        git(repo, 'config', 'user.name', 'SimpleCheck Test')
        git(repo, 'config', 'user.email', 'test@example.invalid')
        git(repo, 'config', 'commit.gpgsign', 'false')
        (repo / 'source.txt').write_text(name + '\n')
        git(repo, 'add', 'source.txt')
        git(repo, 'commit', '-m', 'initial source')
        git(repo, 'push', '--set-upstream', 'origin', 'main')
        heads[name] = git(remote, 'rev-parse', 'main')

    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 40, 110, 0, 0))
    process = subprocess.Popen([str(binary), '--app'], stdin=slave,
                               stdout=slave, stderr=slave, env=env)
    os.close(slave)
    output = bytearray()

    def wait_for(predicate):
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            readable, _, _ = select.select([master], [], [], .05)
            if readable:
                try:
                    output.extend(os.read(master, 65536))
                except OSError:
                    break
            if predicate():
                return
            assert process.poll() is None, output.decode(errors='replace')[-2000:]
        raise AssertionError(output.decode(errors='replace')[-2000:])

    def screen():
        return re.sub(rb'\x1b\[[0-?]*[ -/]*[@-~]', b'', bytes(output))

    try:
        wait_for(lambda: b'~/simplewm' in screen() and b'clean' in screen())
        wm = home / 'simplewm'
        (wm / 'source.txt').write_text('SimpleWM local change\n')
        os.write(master, b'r')
        wait_for(lambda: b'DIRTY' in screen())
        os.write(master, b'p')
        wait_for(lambda: b'Commit message:' in screen())
        os.write(master, b'Update SimpleWM fixture\n')
        wait_for(lambda: git(root / 'simplewm.git', 'rev-parse', 'main') != heads['simplewm'])
        pushed = git(root / 'simplewm.git', 'rev-parse', 'main')
        assert git(wm, 'rev-parse', 'HEAD') == pushed
        assert not git(wm, 'status', '--porcelain')
        for name, sha in heads.items():
            if name != 'simplewm':
                assert git(root / (name + '.git'), 'rev-parse', 'main') == sha

        git(root, 'clone', str(root / 'simplewm.git'), 'upstream-edit')
        upstream = root / 'upstream-edit'
        git(upstream, 'config', 'user.name', 'SimpleCheck Test')
        git(upstream, 'config', 'user.email', 'test@example.invalid')
        (upstream / 'source.txt').write_text('SimpleWM upstream change\n')
        git(upstream, '-c', 'commit.gpgsign=false', 'commit', '-am', 'upstream change')
        git(upstream, 'push')
        os.write(master, b'l')
        wait_for(lambda: (wm / 'source.txt').read_text() == 'SimpleWM upstream change\n')
        assert git(wm, 'rev-parse', 'HEAD') == git(upstream, 'rev-parse', 'HEAD')
        os.write(master, b'q')
        process.wait(timeout=5)
        assert process.returncode == 0
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
        os.close(master)
print('OK real SimpleCheck listing, SimpleWM commit/push/pull, and unchanged peer repositories')
