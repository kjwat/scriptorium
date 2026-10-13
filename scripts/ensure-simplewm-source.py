#!/usr/bin/env python3
"""Restore the optional editable SimpleWM checkout for SimpleCheck/SimpleSave."""
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile


def git(directory, *arguments):
    return subprocess.run(
        ["git", "-c", "core.hooksPath=/dev/null", "-c", "protocol.ext.allow=never",
         "-c", "http.lowSpeedLimit=1", "-c", "http.lowSpeedTime=5",
         "-C", str(directory), *arguments],
        capture_output=True, text=True, timeout=60, check=True,
    ).stdout.strip()


def copy_snapshot(source, destination, relative=Path()):
    for child in source.iterdir():
        if child.name == ".git":
            continue
        target = destination / child.name
        name = relative / child.name
        if not child.is_symlink() and not os.access(child, os.R_OK):
            print(f"Keeping Git version of unreadable installed source: {name}")
            continue
        if target.is_symlink():
            target.unlink()
        if child.is_symlink():
            if target.is_dir():
                shutil.rmtree(target)
            else:
                target.unlink(missing_ok=True)
            target.symlink_to(os.readlink(child))
        elif child.is_dir():
            if target.exists() and not target.is_dir():
                target.unlink()
            target.mkdir(exist_ok=True)
            copy_snapshot(child, target, name)
        elif child.is_file():
            if target.is_dir():
                shutil.rmtree(target)
            shutil.copy2(child, target)
        else:
            raise RuntimeError(f"Unsupported installed source entry: {child}")


def main():
    suite_data = Path(os.environ.get("SIMPLESUITE_SYSTEM_DATA_DIR", "/usr/local/share/simplesuite"))
    data = Path(os.environ.get("SIMPLEWM_SYSTEM_DATA_DIR", str(suite_data.parent / "simplewm")))
    helper = data.parent.parent / 'bin/simplewm-setup'
    if helper.is_file() and (data / 'install-manifest').is_file():
        subprocess.run(['python3', str(helper)], check=True,
                       env=os.environ | {'SIMPLEWM_SYSTEM_DATA_DIR': str(data)})
        return
    home = Path(os.environ.get("HOME", ""))
    if not home.is_absolute() or not home.is_dir():
        raise RuntimeError("HOME must be an existing absolute directory")
    destination = home / "simplewm"
    if destination.exists() or destination.is_symlink():
        try:
            toplevel = Path(git(destination, "rev-parse", "--show-toplevel"))
        except (OSError, subprocess.SubprocessError):
            raise RuntimeError(f"{destination} already exists and is not a Git checkout; left unchanged") from None
        if toplevel.resolve() != destination.resolve():
            raise RuntimeError(f"{destination} is inside another Git checkout; left unchanged")
        print(f"SimpleWM checkout already present: {destination}; local work preserved")
        return

    suite_data = Path(os.environ.get("SIMPLESUITE_SYSTEM_DATA_DIR", "/usr/local/share/simplesuite"))
    system_data = Path(os.environ.get("SIMPLEWM_SYSTEM_DATA_DIR", str(suite_data.parent / "simplewm")))
    manifest = system_data / "install-manifest"
    if not manifest.is_file():
        print("SimpleWM is not installed; optional source checkout skipped")
        return
    metadata = dict(line.split("=", 1) for line in manifest.read_text().splitlines() if "=" in line)
    revision = metadata.get("simplewm_source_sha", "")
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise RuntimeError(f"{manifest} has no valid installed SimpleWM revision")
    repository = os.environ.get("SIMPLEWM_REPO_URL", metadata.get("repository", "https://github.com/kjwat/simplewm.git"))
    snapshot = system_data / "source"

    # Publish only a complete checkout. A failed clone/check-out never leaves
    # ~/simplewm looking like a usable source repository to the other tools.
    with tempfile.TemporaryDirectory(prefix=".simplewm-source-", dir=home) as temporary:
        staging = Path(temporary)
        checkout = staging / "simplewm"
        git(staging, "clone", "--", repository, str(checkout))
        branch = git(checkout, "symbolic-ref", "--short", "HEAD")
        try:
            git(checkout, "cat-file", "-e", revision + "^{commit}")
        except subprocess.CalledProcessError:
            git(checkout, "fetch", "origin", revision)
        git(checkout, "checkout", "-B", branch, revision)
        git(checkout, "branch", "--set-upstream-to=origin/" + branch, branch)

        # The installed source snapshot can contain local edits. Preserve
        # them as working-tree changes on the matching historical baseline,
        # while keeping the newly recovered Git metadata and tracking branch.
        if snapshot.is_dir():
            copy_snapshot(snapshot, checkout)
        if destination.exists() or destination.is_symlink():
            raise RuntimeError(f"{destination} appeared during setup; left unchanged")
        checkout.rename(destination)
    print(f"SimpleWM source ready: {destination}")
    print("SimpleCheck can sync this Git checkout; SimpleSave includes its source and Git history.")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        detail = error.stderr.strip() if isinstance(error, subprocess.CalledProcessError) and error.stderr else str(error)
        sys.exit("SimpleWM source setup failed: " + detail)
