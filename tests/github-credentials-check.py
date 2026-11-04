#!/usr/bin/env python3
"""Exercise the real credential prompts without using the host's credentials."""
import os
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
installer = (root / 'install.sh').read_text()
phase = installer.split('say "Configuring Git"\n', 1)[1].split('setup_gmail=n\n', 1)[0]
script = 'set -euo pipefail\nsay() { :; }; warn() { echo "$*" >&2; };\n' + phase + '\necho CONTINUED\n'

with tempfile.TemporaryDirectory(prefix='scriptorium-credentials-') as tmp:
    base = Path(tmp)
    tools = base / 'bin'
    tools.mkdir()
    curl = tools / 'curl'
    curl.write_text('''#!/usr/bin/env python3
import os
from pathlib import Path
import sys
args = sys.argv[1:]
Path(os.environ['TEST_CURL_LOG']).write_text('called')
Path(args[args.index('-o') + 1]).write_text('{\\n  "login": "kjwat"\\n}\\n')
print(os.environ.get('TEST_HTTP_CODE', '200'), end='')
''')
    curl.chmod(0o755)

    def run_case(name, answers, *, existing=True, unattended=False, http='200'):
        home = base / name
        home.mkdir()
        marker = home / '.config/scriptorium/github-credential-user'
        files = [home / '.git-credentials', home / '.config/git/credentials', marker]
        if existing:
            for path, value in zip(files, (
                    'https://saved-user:saved-token@github.com\nhttps://other:other-token@gitlab.com\n',
                    'https://xdg-user:xdg-token@github.com\n', 'saved-user\n')):
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(value)
                path.chmod(0o600)
        env = dict(os.environ, HOME=str(home), XDG_CONFIG_HOME=str(home / '.config'),
                   GIT_CONFIG_GLOBAL=str(home / '.gitconfig'), GIT_CONFIG_NOSYSTEM='1',
                   PATH=str(tools) + ':' + os.environ['PATH'],
                   SCRIPTORIUM_NONINTERACTIVE='1' if unattended else '0',
                   TEST_CURL_LOG=str(home / 'curl-called'), TEST_HTTP_CODE=http)
        subprocess.run(['git', 'config', '--global', 'credential.helper', 'cache --timeout=1800'],
                       env=env, check=True)
        before = [(p.read_bytes(), p.stat().st_mode, p.stat().st_mtime_ns) if p.exists() else None
                  for p in files]
        result = subprocess.run([os.environ.get('SCRIPTORIUM_TEST_SHELL', 'bash'), '-c', script], input=answers, env=env,
                                text=True, capture_output=True, timeout=5)
        helper = subprocess.check_output(['git', 'config', '--global', '--get', 'credential.helper'],
                                         env=env, text=True).strip()
        after = [(p.read_bytes(), p.stat().st_mode, p.stat().st_mtime_ns) if p.exists() else None
                 for p in files]
        return result, home, before, after, helper

    for name, answers, options in (
            ('blank-pat', 'kjwat\n\n', {}),
            ('blank-username', '\n', {}),
            ('whitespace-pat', 'kjwat\n  \t\n', {}),
            ('eof-pat', 'kjwat\n', {}),
            ('eof-username', '', {}),
            ('unattended', '', {'unattended': True}),
            ('fresh-skip', 'kjwat\n\n', {'existing': False})):
        result, home, before, after, helper = run_case(name, answers, **options)
        assert result.returncode == 0 and 'CONTINUED' in result.stdout, (name, result.stderr)
        assert before == after, f'{name}: saved credentials were modified'
        assert helper == 'cache --timeout=1800', f'{name}: existing helper was replaced'
        assert not (home / 'curl-called').exists(), f'{name}: skip contacted GitHub'
        assert 'cannot be blank' not in result.stderr

    result, home, before, after, helper = run_case('new-token', 'kjwat\nfixture-new-token\n')
    assert result.returncode == 0 and 'CONTINUED' in result.stdout, result.stderr
    assert helper == 'store' and (home / 'curl-called').exists()
    stored = (home / '.git-credentials').read_text()
    assert 'fixture-new-token' in stored and 'gitlab.com' in stored
    assert after[1] == before[1], 'Replacement modified unrelated XDG credentials'
    assert 'fixture-new-token' not in result.stdout + result.stderr
    for name, http in (('rejected-token', '401'), ('forbidden-token', '403')):
        result, home, before, after, helper = run_case(name, 'kjwat\nfixture-rejected\n', http=http)
        assert result.returncode != 0 and 'CONTINUED' not in result.stdout
        assert before == after and helper == 'cache --timeout=1800'
print('OK blank/EOF credentials skip without changing saved tokens or helpers; explicit replacements still validate')
