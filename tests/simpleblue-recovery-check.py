#!/usr/bin/env python3
"""Install the real Simpleblue through Scriptorium and exercise radio recovery.

Usage: python3 tests/simpleblue-recovery-check.py [path/to/simplesuite]
All radio events, BlueZ commands, and installation paths are isolated fixtures.
"""

import codecs
import fcntl
import os
from pathlib import Path
import pty
import runpy
import select
import shlex
import shutil
import struct
import subprocess
import sys
import tempfile
import termios
import time


ROOT = Path(__file__).resolve().parents[1]
SUITE = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else ROOT.parent / "simplesuite"


def run(*args, **kwargs):
    return subprocess.run(args, check=True, text=True, capture_output=True, **kwargs)


def check():
    if sys.platform != "linux":
        print("simpleblue recovery check: Linux only")
        return
    if not (SUITE / "simpleblue.c").is_file():
        raise SystemExit("Pass the SimpleSuite checkout as the first argument.")
    # Reuse Suite's terminal renderer to check visible text after ncurses diffs.
    Screen = runpy.run_path(str(SUITE / "tests/simplevol-responsiveness-pty.py"))["Screen"]
    with tempfile.TemporaryDirectory(prefix="scriptorium-blue-check-") as temporary:
        base = Path(temporary)
        checkout = base / "suite"
        bindir = base / "system-bin"
        datadir = base / "system-data"
        fakebin = base / "test-bin"
        test_home = base / "home"
        for directory in (checkout, bindir, datadir, fakebin, test_home):
            directory.mkdir()
        for name in ("simpleblue.c", "Makefile", "program-manifest.sh", "uninstall.sh"):
            shutil.copy2(SUITE / name, checkout / name)
        (checkout / ".gitignore").write_text("/build/\n")
        for args in (("init", "-q"), ("add", "."),
                     ("-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                      "commit", "-qm", "Radio recovery fixture")):
            run("git", "-C", str(checkout), *args)

        radio = base / "rfkill"
        radio.write_bytes(struct.pack("=IBBBB", 0, 2, 0, 1, 0))
        (base / "controller-delay").write_text("2")
        (base / "pairing").write_text("old")
        (base / "trusted").write_text("yes")
        backend = fakebin / "bluetoothctl"
        backend.write_text("""#!/usr/bin/env python3
import os
from pathlib import Path
import struct
import sys
base = Path(os.environ['SIMPLEBLUE_FIXTURE'])
args = sys.argv[1:]
def log(command):
    with (base / 'commands').open('a') as file:
        file.write(command + '\\n')
def info():
    print('Device 10:20:30:40:50:60 (public)')
    print('\\tName: Recovery Speaker')
    state = (base / 'pairing').read_text()
    print('\\tPaired: ' + ('no' if state == 'removed' else 'yes'))
    print('\\tConnected: ' + ('yes' if state == 'connected' else 'no'))
    print('\\tTrusted: ' + (base / 'trusted').read_text())
log(' '.join(args))
if args and args[0] == 'list':
    blocked = struct.unpack('=IBBBB', (base / 'rfkill').read_bytes())[3]
    if not blocked:
        remaining = int((base / 'controller-delay').read_text())
        if remaining:
            (base / 'controller-delay').write_text(str(remaining - 1))
        else:
            print('Controller 11:22:33:44:55:66 Fixture [default]')
elif args and args[0] == 'show':
    print('Controller 11:22:33:44:55:66 (public)')
    print('\\tName: Fixture')
    print('\\tPowered: yes')
elif args and args[0] == 'devices':
    print('Device 10:20:30:40:50:60 Recovery Speaker')
elif args and args[0] == 'power':
    print('Changing power succeeded')
elif args and args[0] == 'connect':
    if (base / 'pairing').read_text() == 'old':
        print('Failed to connect: org.bluez.Error.Failed br-connection-key-missing')
        sys.exit(1)
    (base / 'pairing').write_text('connected')
    print('Connection successful')
elif args and args[0] == 'remove':
    (base / 'pairing').write_text('removed')
    (base / 'trusted').write_text('no')
    print('Device has been removed')
elif args and args[0] == 'trust':
    (base / 'trusted').write_text('yes')
    print('Changing trust succeeded')
else:
    for line in sys.stdin:
        command = line.strip()
        log(command)
        if command.startswith('info '):
            info()
        elif command == 'scan on':
            print('Discovery started')
        elif command.startswith('pair '):
            (base / 'pairing').write_text('fresh')
            print('Pairing successful')
        elif command == 'quit':
            break
        sys.stdout.flush()
""")
        backend.chmod(0o755)
        environment = os.environ.copy()
        environment.update({
            "HOME": str(test_home), "SCRIPTORIUM_OFFLINE": "1",
            "SIMPLESUITE_DIR": str(checkout), "SIMPLESUITE_NETWORK_ROLE": "none",
            "SIMPLESUITE_PROGRAM_FILTER": "simpleblue", "SIMPLESUITE_INSTALL_PACKAGES": "0",
            "SIMPLESUITE_SYSTEM_BIN_DIR": str(bindir),
            "SIMPLESUITE_SYSTEM_DATA_DIR": str(datadir),
            "SIMPLEBLUE_FIXTURE": str(base), "TERM": "xterm-256color",
            "PATH": str(fakebin) + os.pathsep + os.environ["PATH"],
            "CPPFLAGS": "-DSIMPLEBLUE_RFKILL_DEVICE=" + shlex.quote('"' + str(radio) + '"'),
        })
        run(str(ROOT / "scripts/install-simplesuite.sh"), env=environment)
        installed = bindir / "simpleblue"
        assert installed.read_bytes() == (checkout / "build/simpleblue").read_bytes()
        assert "blue simpleblue\n" in (datadir / "command-abbreviations").read_text()
        aliases = run("sh", "-c", '. "$1"; scriptorium_program_aliases Linux 0',
                      "sh", str(ROOT / "scripts/simple-programs.sh"), env=environment).stdout
        assert "blue:simpleblue\n" in aliases
        shutil.rmtree(checkout / "build")

        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 100, 0, 0))
        process = subprocess.Popen([str(installed)], stdin=slave, stdout=slave,
                                   stderr=slave, env=environment, start_new_session=True)
        os.close(slave)
        output = bytearray()
        screen = Screen(24, 100)
        decoder = codecs.getincrementaldecoder("utf-8")("replace")

        def wait_for(needle):
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline:
                if needle.decode() in "\n".join(screen.lines()):
                    return
                if select.select([master], [], [], 0.1)[0]:
                    try:
                        data = os.read(master, 65536)
                        output.extend(data)
                        screen.feed(decoder.decode(data).encode("ascii", errors="replace"))
                    except OSError:
                        break
            raise AssertionError(f"Missing {needle!r}:\n" + "\n".join(screen.lines()))

        try:
            wait_for(b"press p to turn it on")
            assert radio.read_bytes() == struct.pack("=IBBBB", 0, 2, 0, 1, 0)
            assert "power on\n" not in (base / "commands").read_text()
            os.write(master, b"p")
            wait_for(b"powered on")
            wait_for(b"Recovery Speaker")
            assert radio.read_bytes() == struct.pack("=IBBBB", 0, 2, 3, 0, 0)
            assert (base / "controller-delay").read_text() == "0"
            assert "power on\n" in (base / "commands").read_text()
            os.write(master, b"\n")
            wait_for(b"Pairing key rejected:")
            wait_for(b"re-pair needed")
            assert "remove 10:20:30:40:50:60\n" not in (base / "commands").read_text()
            assert "pair 10:20:30:40:50:60\n" not in (base / "commands").read_text()
            os.write(master, b"x")
            wait_for(b"remove its pairing?")
            os.write(master, b"n")
            wait_for(b"Forget cancelled.")
            assert (base / "pairing").read_text() == "old"
            assert "remove 10:20:30:40:50:60\n" not in (base / "commands").read_text()
            os.write(master, b"x")
            wait_for(b"remove its pairing?")
            os.write(master, b"y")
            wait_for(b"Forgot Recovery Speaker.")
            assert (base / "pairing").read_text() == "removed"
            os.write(master, b"\n")
            wait_for(b"Paired, trusted, and connected Recovery Speaker.")
            assert (base / "pairing").read_text() == "connected"
            assert (base / "trusted").read_text() == "yes"
            assert (base / "commands").read_text().count("remove 10:20:30:40:50:60\n") == 1
            os.write(master, b"q")
            assert process.wait(timeout=5) == 0
        finally:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=5)
            os.close(master)
    print("simpleblue recovery: Scriptorium installation, blue alias, radio recovery, rejected keys, cancellation, and confirmed re-pairing passed")


if __name__ == "__main__":
    check()
