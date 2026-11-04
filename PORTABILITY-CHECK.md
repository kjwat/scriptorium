# Installer portability check — 2026-11-04

The installer targets current Debian/Ubuntu, Arch-family, Fedora, Alpine stable
with main/community, Void, openSUSE Tumbleweed, FreeBSD and macOS 14.2+.
Unsupported RHEL/SLES/Leap releases retain their existing dependency gate.

## Repairs

- Refresh and restart Scriptorium before installing its dependencies and apps;
  carry a supplied Tailscale authentication key through that restart.
- Preserve existing GitHub credentials/helper when Enter or EOF skips either
  credential prompt. Use Bash 3.2-compatible initialization and username matching.
- Preserve an existing SimpleOS daemon, while allowing a missing daemon's first
  installation on a fresh machine. Explicit preserve/skip choices still apply.
- Request Fedora's official `ffmpeg-free-devel`, preserving an already installed
  RPM Fusion development package; request openSUSE's SDL pkg-config capability
  and include Arch's split GLib development tools.
- Build absent Calibre/libsidplayfp dependencies on Alpine stable from pinned,
  checksum-verified recipes as locally signed native APKs. No edge/testing
  repository or permanent trust key is added. The builder clears inherited
  sudo caller IDs before building Calibre and retains its PoDoFo PDF extension.
- Support both libsidplayfp 2 and 3 in SimplePlay, retaining unconsumed stereo
  samples across arbitrary read sizes, seeks and track changes.
- Build a pinned private FFmpeg when the native format check fails. Include the
  source SDK dependencies in both package selection and the existing-dependency
  shortcut. Copy runtime libraries with the player; relative loader paths keep
  the installed programs independent of the source/build directory.

## Validation scope

Native Linux checks use isolated amd64 roots from official OCI images, native
package indexes and native compilers. They are not booted desktop/service tests.
No distro repository changes or package transactions were applied to the Ubuntu
host for these isolated tests. Full refresh of the Ubuntu host is checked
separately below.

| Platform | Evidence |
| --- | --- |
| Ubuntu 24.04 | Native playback, codec corpus, audio/video, staging and installer regression checks passed; full system refresh completed successfully. Installed programs match upstream Suite 7ccf615 byte for byte; the existing daemon and all 16 package holds are preserved. Four missing SDK packages were installed, with no package upgrades or removals. |
| Debian 13 | Real APT resolves the complete requested package transaction with official repositories. |
| Arch rolling | Real pacman resolves the complete transaction. SimpleTerm, SimplePDF and SimplePlay compile; SID 3 streaming passes. Private FFmpeg builds; staged player/core pass with build libraries hidden and through the canonical install-full interface. |
| Fedora 45 | Real DNF resolves the complete transaction with official `ffmpeg-free-devel`; transaction deliberately declined after resolution. |
| Alpine 3.24.3 | Real APK resolves the complete transaction. libsidplayfp, APSW, html5-parser and Calibre build/install; both Calibre command versions run and real HTML-to-EPUB-to-PDF conversion passes. SimpleTerm/SimplePDF compile and SID 2 streaming passes. Private FFmpeg builds; staged player/core pass with build libraries hidden and through the canonical install-full interface. |
| openSUSE Tumbleweed | Real zypper resolves the complete transaction. SimpleTerm/SimplePDF/SimplePlay compile. Private FFmpeg builds; staged player/core pass with build libraries hidden and through the canonical install-full interface. |
| Void rolling glibc | Real XBPS resolves the complete requested transaction. |
| macOS | Platform routing/package mocks pass. Actual Bash 3.2 parses the whole installer and runs initialization plus all credential scenarios. Native Homebrew/macOS runtime was not available. |
| FreeBSD | Platform routing, package/bootstrap and staged service/helper regression checks pass. A native FreeBSD runtime was not available. |

The Scriptorium regression set consists of 19 checks, including new Linux
package/provider coverage and fresh/existing service defaults. SimpleSuite's
staged `make install-full` check verifies that a previously unlisted application
and the desktop apps are included through the canonical complete interface.
SimplePlay's staged installer checks repeat installation, uninstall, settings
preservation and symlink escapes. Private-library checks additionally hide the
build SDK and execute the staged player/core with no loader environment.

The Ubuntu codec corpus decodes 35 additional codec families including MIDI,
SID, MOD and NSF. Engine, headless IPC, PCM/SRC/downmix/gain, deinterlacing and
pixel comparison checks pass. GTK menu/presentation checks require Xvfb and
xdotool, which are absent on this host; those checks were not counted as passed.

SimpleSuite implementation: `7ccf6156bdfa7ab6591a2aad0523209dd6687a27`.
Scriptorium implementation: `f8cee7a9e5f1e74de70903bcd7a961627952b831`.

Local detailed evidence and isolated roots are under `build/distro-audit/`;
SimpleSuite playback logs are `/tmp/simpleplay-*-local.log`.
