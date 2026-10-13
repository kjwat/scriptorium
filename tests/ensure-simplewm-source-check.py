#!/usr/bin/env python3
"""Verify optional WM source recovery against disposable local Git history."""
import os
from pathlib import Path
import subprocess
import tempfile

repo = Path(__file__).resolve().parent.parent
script = repo / "scripts/ensure-simplewm-source.py"

with tempfile.TemporaryDirectory(prefix="simplewm-source-check-") as temporary:
    root = Path(temporary)
    upstream = root / "upstream"
    upstream.mkdir()
    git_env = os.environ | {
        "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_TERMINAL_PROMPT": "0",
    }

    def git(directory, *args):
        return subprocess.check_output(["git", "-C", str(directory), *args],
                                       env=git_env, stderr=subprocess.PIPE).decode().strip()

    git(upstream, "init", "--initial-branch=main")
    git(upstream, "config", "user.name", "Source Test")
    git(upstream, "config", "user.email", "test@example.invalid")
    (upstream / "simplewm.c").write_text("installed source\n")
    (upstream / "image").mkdir()
    (upstream / "image/settings.ini").write_text("public template\n")
    git(upstream, "add", ".")
    git(upstream, "-c", "commit.gpgsign=false", "commit", "-m", "installed revision")
    installed = git(upstream, "rev-parse", "HEAD")
    (upstream / "simplewm.c").write_text("newer upstream source\n")
    git(upstream, "-c", "commit.gpgsign=false", "commit", "-am", "newer revision")
    newest = git(upstream, "rev-parse", "HEAD")
    home = root / "home"
    home.mkdir()
    data = root / "system/share/simplewm"
    data.mkdir(parents=True)
    env = git_env | {
        "HOME": str(home),
        "SIMPLESUITE_SYSTEM_DATA_DIR": str(data.parent / "simplesuite"),
        "SIMPLEWM_REPO_URL": str(upstream),
    }
    env.pop("SIMPLEWM_SYSTEM_DATA_DIR", None)

    def run(success=True):
        result = subprocess.run(["python3", str(script)], env=env, text=True,
                                capture_output=True, timeout=15)
        assert (result.returncode == 0) == success, result.stdout + result.stderr
        assert not list(home.glob(".simplewm-source-*")), "setup leaked its staging directory"
        return result

    run()
    assert not (home / "simplewm").exists(), "installed-WM detection was not optional"
    manifest = data / "install-manifest"
    manifest.write_text("simplewm_source_sha=" + installed + "\nrepository=https://example.invalid/simplewm.git\n")
    snapshot = data / "source"
    snapshot.mkdir()
    (snapshot / "simplewm.c").write_text("local installed source edit\n")
    (snapshot / ".git").mkdir()
    (snapshot / ".git/config").write_text("must not replace Git metadata\n")
    (snapshot / "image").mkdir()
    restricted = snapshot / "image/settings.ini"
    restricted.write_text("public template\n")
    restricted.chmod(0)
    result = run()
    checkout = home / "simplewm"
    assert git(checkout, "rev-parse", "HEAD") == installed
    assert git(checkout, "rev-parse", "@{upstream}") == newest
    assert git(checkout, "remote", "get-url", "origin") == str(upstream)
    assert (checkout / "simplewm.c").read_text() == "local installed source edit\n"
    assert (checkout / "image/settings.ini").read_text() == "public template\n"
    assert "M simplewm.c" in git(checkout, "status", "--porcelain")
    git(checkout, "fsck", "--full")
    if os.geteuid() != 0:
        assert "Keeping Git version of unreadable installed source" in result.stdout
    (checkout / "simplewm.c").write_text("personal work\n")
    manifest.write_text("simplewm_source_sha=" + newest + "\n")
    run()
    assert (checkout / "simplewm.c").read_text() == "personal work\n"
    assert git(checkout, "rev-parse", "HEAD") == installed

    # A non-repository with the expected name is personal data, not a
    # disposable failed checkout that setup is allowed to replace.
    checkout.rename(home / "saved-checkout")
    checkout.mkdir()
    (checkout / "keep.txt").write_text("keep existing directory\n")
    run(False)
    assert (checkout / "keep.txt").read_text() == "keep existing directory\n"
    (checkout / "keep.txt").unlink()
    checkout.rmdir()
    env["SIMPLEWM_REPO_URL"] = str(root / "missing-upstream")
    run(False)
    assert not checkout.exists(), "failed clone published a partial checkout"
    env["SIMPLEWM_REPO_URL"] = str(upstream)
    manifest.write_text("simplewm_source_sha=" + "0" * 40 + "\n")
    run(False)
    assert not checkout.exists(), "unknown installed revision published a partial checkout"
print("OK optional WM checkout, installed revision/history, installed edits, dirty-work preservation, and failed-clone cleanup")
