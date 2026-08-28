# Scriptorium

A reproducible command-line writing environment for SimpleSuite and related
terminal tools.

`install.sh` installs package dependencies, clones or updates
[SimpleSuite](https://github.com/kjwat/simplesuite), builds it, installs the
binaries into `~/.local/bin`, links Scriptorium-managed dotfiles, and prepares
the local shell environment. It also establishes **Keelan's Networking
Trident** in the same run: SimpleServe for the intranet, Tailscale for the
encrypted extranet, OpenSSH client and daemon access, and the `setup-server`
entry point for the public website. The Trident supports Debian/Ubuntu, Fedora,
Arch, Alpine, Void, openSUSE Tumbleweed, FreeBSD, and macOS.

## Keelan's Networking Trident

- **Intranet:** SimpleServe clients discover and mount shares; explicitly
  promoted servers also publish them over NFS/SMB.
- **Extranet:** Tailscale carries those same shares over the encrypted tailnet.
- **Website:** `setup-server` provisions Caddy, the local Stripe fulfillment
  worker and purchase-recovery mail, blog sync, and the Cloudflare tunnel using
  Scriptorium-owned recovery code and the site payload in `~/website`.

Every participating client and server also receives both the OpenSSH `ssh`
client and `sshd` daemon. Linux package families install their native OpenSSH
packages; FreeBSD and macOS use the copies supplied by the operating system.
Scriptorium leaves SSH keys, daemon policy, and service activation at the
platform package defaults.

Scriptorium installs the first two prongs, OpenSSH, and the website bootstrap.
Run `setup-server` only on a machine intended to serve
`keelanwatlington.com`. A fresh interactive installation starts with client
mode and offers that full server promotion at the end. Declining leaves a
mount-only client and prints the same `setup-server` command for later.

When `setup-server` is run on an existing server, its first question offers a
safe return to client mode before it pulls or changes the website checkout.
Demotion creates a protected backup of store/tunnel state, stops and disables
the website stack, withdraws SimpleServe-managed NFS/SMB exports and boot
mounts, and preserves client mounts, the checkout, data, and installed packages
for a later promotion. `setup-server --client` selects that path directly.

## First Run

```sh
git clone https://github.com/kjwat/scriptorium.git
cd scriptorium
./install.sh
```

Run this from an interactive shell. `install.sh` detects Linux distributions,
FreeBSD, and macOS automatically. Linux and FreeBSD package installation needs
either a root shell or working `sudo`; macOS needs Homebrew and Apple Command
Line Tools. A base Alpine installation bootstraps Bash automatically. Bash users
receive `~/.bashrc` setup, and zsh users receive matching `~/.zshrc` setup.
When an interactive installation finishes, it starts a configured shell so
commands such as `words` and `simplewords` work immediately. An unattended
installation instead prints the shell file to source before using the commands.
On FreeBSD, Linux, and macOS, the installer asks one networking question:
`Join Keelan's Networking Trident?` Answering yes creates a **client**. It
installs discovery/mount dependencies and both OpenSSH programs, installs
Tailscale, and enables a mount-only SimpleServe service. Client mode is
enforced: `simpleserve share` is rejected and NFS/Samba publishing services
are not installed or enabled. Answering no leaves any existing networking
installation untouched.

An existing `/etc/simpleserve-role` is preserved automatically, so rerunning
Scriptorium on a server cannot silently demote it. Pre-role legacy server
installs are also recognized as servers. For unattended installs, set
`SCRIPTORIUM_NONINTERACTIVE=1` and choose
`SCRIPTORIUM_NETWORK_ROLE=client`, `server`, or `none`. The older
`SIMPLESUITE_INSTALL_SIMPLESERVE=1|0` switch remains compatible, but `1` now
preserves an existing role and otherwise selects the safe client default.
Server publishing is enabled only by an explicit `server` role or
`setup-server` promotion.

Tailscale follows the Trident choice automatically; there is no second prompt.
It uses the platform's native trusted package source—Tailscale's signed
repositories where required—then enables the daemon through systemd, OpenRC,
runit, FreeBSD rc.d, or the supported macOS Homebrew/app path. It verifies a
live `100.64.0.0/10` address before SimpleServe is built. If the machine is
already connected, the hard no-op path does not touch its package database,
service, node identity, or preferences, and `tailscale up` is not run again. A
new interactive machine prints a browser login URL that can be approved from
any device.

For a completely unattended run, create a one-off or otherwise appropriately
scoped auth key in the Tailscale admin console, place it in a protected file,
and pass its absolute path:

```sh
SCRIPTORIUM_NONINTERACTIVE=1 \
SCRIPTORIUM_NETWORK_ROLE=client \
SCRIPTORIUM_INSTALL_TAILSCALE=1 \
SCRIPTORIUM_GIT_NAME='Your Name' \
SCRIPTORIUM_GIT_EMAIL='you@example.com' \
TAILSCALE_AUTH_KEY_FILE=/private/tailscale-auth.key \
./install.sh
```

The Git name and email variables are optional when a global Git identity is
already configured. Unattended mode skips the optional GitHub PAT and Gmail
setup, disables Git credential prompts, does not start a shell at the end, and
uses non-prompting package-manager/sudo flags. Run it as root or configure
passwordless `sudo` for the required commands; otherwise it fails instead of
waiting for a password.

The key is passed through Tailscale's `file:` mechanism and is never copied to
Scriptorium, shell history, or the process command line. `TAILSCALE_AUTH_KEY`
is also accepted for ephemeral provisioning and is removed from the installer's
environment before unrelated child processes run. Set
`SCRIPTORIUM_INSTALL_TAILSCALE=0` for a LAN-only installation. New nodes default
to `TAILSCALE_ACCEPT_DNS=0`, matching the current server and leaving system DNS
alone; set it to `1` if tailnet DNS should replace that behavior. An optional
`TAILSCALE_HOSTNAME` supplies an explicit MagicDNS machine name.

### Two-machine fresh start

On the writing machine, run `./install.sh`, join the Trident, then connect to
the server's advertised drive:

```sh
simpleserve connect
```

With one discovered share, `connect` asks for confirmation; with several, it
shows a numbered choice. The selected share is mounted under
`~/SimpleServe/SERVER/SHARE` and remembered across restarts. The writing
machine remains unable to publish files.

While the client is at home, SimpleServe prefers the server's LAN address but
also remembers and probes its Tailscale address. If the LAN route disappears,
the daemon safely releases the stale managed mount and reconnects the same
`~/SimpleServe/SERVER/SHARE` path over NFSv3 through Tailscale. Returning home
restores LAN preference. `simpletrident` reports each remembered fallback as
ready or unreachable, so a connected Tailscale client alone is not treated as
proof that remote files are available.

On the machine that will host `keelanwatlington.com`, run `./install.sh`, join
the Trident, and then run the installed command after GitHub access is ready:

```sh
setup-server
```

`setup-server` safely clones or fast-forwards `~/website`, installs any missing
server-only NFS/Samba dependencies, and explicitly promotes SimpleServe to
`server (publish + mount)` before touching website services. Scriptorium's own
idempotent provisioner then configures Caddy, Cloudflare Tunnel, the local
Stripe fulfillment and purchase-recovery mail service, generated-blog checks,
protected local state, and final local/public health verification. The website
checkout supplies site content and runtime programs only; `setup-server` never
executes provisioning code from that checkout. SMTP provider credentials remain
in the protected `store.env`; reruns and server-state backups preserve them. It
refuses to update a dirty website checkout. The
website prong uses systemd on Debian/Fedora/Arch/openSUSE,
OpenRC on Alpine, runit on Void, rc.d on FreeBSD, and launchd on macOS. An
unchanged rerun rewrites no managed file and restarts no healthy service.

For the remotely managed Cloudflare tunnel, setup reads the account and tunnel
identity from the protected connector token and reconciles the public ingress
for `keelanwatlington.com` and `www.keelanwatlington.com` to
`http://localhost:8080` through Cloudflare's tunnel-configuration API. It also
reconciles only those two exact DNS names to the connector's canonical
`<tunnel UUID>.cfargotunnel.com` CNAME target through Cloudflare's zone API.
The first run accepts a Cloudflare API token with **Account / Cloudflare Tunnel
/ Edit**, **Zone / Zone / Read**, and **Zone / DNS / Edit** for
`keelanwatlington.com`, stores it as protected migration state, and reuses it
to verify or repair both parts on later runs. Existing unrelated DNS records
and Cloudflare private-network routes are left untouched.

An API token saved by an older Scriptorium release may have only Cloudflare
Tunnel Edit. Setup detects that the zone is not visible and stops safely; rerun
it once with a replacement token via `CLOUDFLARE_API_TOKEN` or
`--cloudflare-api-token-file`. No DNS record needs to be edited in the
Cloudflare dashboard.

After promotion, register each local filesystem the server should expose, for
example `simpleserve share /media/T7 --name Writing`. Server mode can also
mount shares from another Trident server.

When replacing the current website host, first make its protected migration
bundle with `~/scriptorium/scripts/backup-server-state.sh /private/path`,
then run `setup-server --state-backup /private/path` on the new machine. This
restores its Stripe/order state and either its protected replica token or its
locally managed tunnel credentials in the same pass. For a remotely managed
tunnel, the bundle also carries the protected Tunnel/DNS management API token
so the new server verifies and, if necessary, repairs the public ingress and
the two hostname associations without dashboard work.

For a bare-metal rebuild, clone and install the known-good Scriptorium version,
run `setup-server`, and provide the Stripe webhook secret and a Cloudflare
replica token if no migration bundle survived the wipe. A remotely managed
tunnel also needs a Cloudflare API token with Account / Cloudflare Tunnel /
Edit, Zone / Zone / Read, and Zone / DNS / Edit, supplied interactively, as
`CLOUDFLARE_API_TOKEN`, or with `--cloudflare-api-token-file`. No manual
preparation of `~/website` or public-hostname dashboard routes is required;
Scriptorium obtains the site as payload and reconciles the tunnel ingress and
exact public DNS records itself.

## What It Installs

SimpleSuite programs:

- `simplebrowse`
- `simplewords`
- `simplefiles`
- `simplemail`
- `simplenet`
- `simplecal`
- `simpleclock`
- `simpleflac`
- `simplegame`
- `simplepdf`
- `simplepod`
- `simpleradio`
- `simplenews`
- `simplestats`
- `simplever`
- `simplevis`

When selected on FreeBSD, Linux, or macOS, the installer also includes `simpleserve`
and its `simpleserved` system daemon.

Scriptorium also builds and installs two ncurses dashboards: `simplecheck` for
the `~/writing`, `~/scriptorium`, `~/simplesuite`, and `~/website` Git
repositories, and `simpletrident` for verifying the installed Trident prongs
that apply to the machine's role.

Runtime and workflow tools installed by the package script include, depending
on platform availability:

- build tools, `pkg-config`, ncurses, GIO/GLib, libcurl, and OpenSSL headers
- Python GI, GTK 3 introspection, and WebKit2GTK 4.1 for SimpleBrowse v4
  JavaScript mode on supported Linux and BSD families; macOS uses WKWebView
- `git`, `mpv`, `links`, `fzf`, `calcurse`
- `isync`/`mbsync` and `msmtp` for SimpleMail
- NetworkManager, iwd, or wpa_supplicant plus `iw`, `ip`, and `ping` for
  SimpleNet Wi-Fi management and adapter diagnostics
- `pdftotext`/poppler and `pandoc` for SimplePDF
- `zip`, `unzip`, `tar`, `file`, `less`, `curl`, `ca-certificates`, `rsync`
- `util-linux`, UDisks/GVfs, and native ext/FAT/exFAT/NTFS checkers for
  SimpleFiles drive discovery and mount recovery, plus cron tooling for
  SimpleCal reminder fallback
- in SimpleServe client mode, NFS client and Avahi discovery utilities for real
  filesystem mounts; server promotion adds NFS publishing, Samba, and the
  remaining dual-protocol server dependencies
- when selected, the official/native Tailscale package and persistent daemon
  for SimpleServe's encrypted remote transport on every Trident platform
- clipboard, desktop-open, trash, and audio helper packages where available

Supported package targets are current Debian/Ubuntu, Arch-family distributions,
Fedora, Alpine (with `main` and `community`), Void, openSUSE Tumbleweed,
FreeBSD (`pkg`), and macOS/Homebrew. RHEL/CentOS-family releases, SLES, and openSUSE Leap do not
consistently carry the complete feature set in their default repositories; the
installer stops before changing packages unless the dependencies were already
provisioned. If platform detection is unknown, `scripts/install-packages.sh`
asks for a package family and stores the choice in
`~/.config/simplesuite/family`.

Use a currently supported distro release with its official repositories
enabled. In particular, full SimpleBrowse JavaScript mode needs WebKitGTK 4.1;
if an older release does not provide a required package, installation stops
with repository/release guidance instead of leaving a partially working build.

On macOS 14.2 or newer, the same `./install.sh` path validates the selected SDK,
installs the Homebrew package set once, and hands the checkout to SimpleSuite's
native Darwin build without repeating the package transaction. SimpleBrowse
uses WKWebView, SimpleFiles uses Disk Arbitration and Finder-compatible Trash,
SimpleNet uses CoreWLAN, SimpleStats uses Mach and IOKit, SimpleVis uses a Core
Audio process tap, and reminders use per-user launchd agents. No WebKitGTK or
PulseAudio compatibility package is installed for those native features.

## SimpleSuite Checkout

SimpleSuite is cloned to:

```text
~/simplesuite
```

Override this with:

```sh
SIMPLESUITE_DIR=/path/to/simplesuite ./install.sh
SIMPLESUITE_REPO_URL=https://example/repo.git ./install.sh
```

If the checkout already exists, Scriptorium updates it with `git pull
--ff-only`. Scriptorium resolves that moving `main` checkout to an exact commit,
requires a clean tree, and refuses installation unless that commit passes the
SimpleWords release gate. It verifies the installed `simplewords --version`
and `~/.local/share/simplesuite/install-manifest` against the resolved commit,
so a captured image retains its source provenance. The SimpleSuite build
installs binaries to `~/.local/bin`, including `simplesuite-uninstall`. Shared
audio assets are installed under:

```text
~/.local/share/simplesuite/simplecal-alarm.mp3
~/.local/share/simplesuite/simplewords-typewriter.wav
~/.local/share/simplesuite/simplewords-typewriter-alt.wav
~/.local/share/simplesuite/simplewords-typewriter-space.wav
~/.local/share/simplesuite/simplewords-typewriter-enter.wav
~/.local/share/simplesuite/simplewords-typewriter-delete.wav
```

The same directory also carries the sound-provenance notice and the internal
source-checkout record used by destructive uninstallation.

When SimpleServe is selected on FreeBSD or Linux, installation also installs,
enables, starts, and verifies its privileged service. This is the piece that
turns discovered NFS shares into real VFS mounts and exports every active Linux
share over SMB as well. The install fails clearly if its NFS, Samba, or Avahi
runtime commands are absent or that system service cannot be made ready; set
`SIMPLESUITE_INSTALL_SIMPLESERVE_SYSTEM=skip` only when intentionally managing
the daemon separately.

On Linux, SimpleServe records shared local drives by UUID in a marked managed
block in `/etc/fstab`, using `nofail` so an unplugged disk cannot block boot.
Unsharing a drive removes its entry, and both normal and purge uninstall remove
the entire managed block while preserving unrelated fstab mounts. SimpleServe
keeps Linux SMB shares in `/etc/samba/simpleserve.conf`; uninstall removes that
generated file and its marked `smb.conf` include while preserving unrelated
Samba settings and shares.

SimpleWords typewriter audio is native and needs no additional player or audio
development package. Its config is created at
`~/.config/simplewords/config` only when missing. The feature remains off by
default; volume `70` is recommended when it is enabled. Existing SimpleWords
config is never overwritten.

## Managed Dotfiles

Scriptorium currently links these paths into the checkout:

- `~/.config/calcurse/` -> `dotfiles/calcurse/`
- `~/.links/` -> `dotfiles/links/`
- `~/.config/simplecal/` -> `dotfiles/simplecal/`
- `~/.config/simplefiles/config` -> `dotfiles/simplefiles/config`
- `~/.config/simplenews/config` -> `dotfiles/simplenews/config`
- `~/.config/simplenews/urls` -> `dotfiles/simplenews/urls`

The SimpleCal dotfile directory includes both configuration and local calendar
data:

```text
dotfiles/simplecal/config
dotfiles/simplecal/data/events/
dotfiles/simplecal/data/reminders.db
```

Scriptorium writes the current SimpleCal config with `data_dir=data`, plus
defaults for reminder lead times, theme, today color, first day of week, clock
format, reminder auto-install state, and legacy migration state. Older
installations may still contain a legacy `DATA_DIR` line; SimpleCal accepts it,
but the lower-case `data_dir` key is the current form.

Most other SimpleSuite applications either use default local state paths or
create their own config files on first run. SimpleSuite's installer creates a
missing SimpleWords config without making it a Scriptorium-managed symlink.
Scriptorium only links files that exist in this repo. SimpleBrowse has no
Scriptorium-managed default config; it creates
`~/.config/simplebrowse/bookmarks` only when bookmarks are used.
SimpleBrowse v4 also installs and verifies the `simplebrowse-webkitd` and
`simplebrowse-jsdump` helpers. On supported Linux systems these enable `--js`,
the `B` (or legacy `J`) reload key, JavaScript dumps, and form replay through
WebKitGTK.

The managed SimpleFiles config follows the current startup behavior:
SimpleFiles opens in the invoking shell's current directory, or in a directory
passed as its command-line argument. The removed `START_DIR` config key is not
written by Scriptorium.

The managed SimpleNews URL file is preloaded with categorized technology,
poetry, literature, spirituality, education, classics/language, and podcast
feeds. Editing the linked file edits the copy tracked inside Scriptorium.

## Included Radio Playlists

The `playlists/` directory contains ready-to-use M3U station collections for
classical, grunge, house, jazz, lo-fi, relaxation, and techno. They remain in
the checkout rather than being copied elsewhere. Browse all of them with:

```sh
simpleradio ~/scriptorium/playlists
```

## Generated Files and System Adjustments

The installer may create or modify:

- `~/.bashrc`
- `~/.zshrc` when zsh is the login shell
- `~/.gitconfig`
- `~/.git-credentials`
- `~/.config/scriptorium/github-credential-user` when a PAT is stored
- `~/.config/simplemail/config`
- `~/.config/simplewords/config` when it does not already exist
- `~/.local/share/simplesuite/` for alarm/typewriter assets and install metadata
- `~/.mbsyncrc`
- `~/.msmtprc`
- `~/.config/isyncrc`
- `~/.config/systemd/user/simplecal-reminders.service`
- the user's crontab, if systemd user services are unavailable
- `~/Downloads`, `~/Music`, and `~/Podcasts`

On APT systems, the installer disables stale `cdrom:` package sources before
installing dependencies and refreshes the package lists. On systems where an
AppArmor `mbsync` profile is active, it adds the SimpleMail Maildir permissions
to `/etc/apparmor.d/local/mbsync`, may add the local include to the packaged
profile, and reloads that profile. These operations use root privileges
(directly when already root, otherwise through `sudo`) and modify system
configuration outside the home directory.

Selecting Tailscale may also install the platform's Tailscale repository
metadata or native package, its persistent system service, and its machine
identity under Tailscale's system state directory. Debian/Ubuntu use
`/usr/share/keyrings/tailscale-archive-keyring.gpg` and
`/etc/apt/sources.list.d/tailscale.list`; Fedora and openSUSE use the official
RPM repository definitions. Scriptorium never writes an auth key into those
paths.

`~/.bashrc` receives `~/.local/bin` on PATH and these aliases. Every
user-facing tool also gets a relative short-command symlink beside its full
binary, so the short names resolve immediately without waiting for the parent
shell to reload its startup file. Platform- or role-specific aliases exist only
when their target is installed, and installers refuse to overwrite unrelated
commands. On Linux, `simpleblue` and `blue` are installed without forcing the
optional BlueZ system stack onto machines whose owners do not want Bluetooth;
`simpleblue --setup-help` shows the opt-in setup for each supported platform.
SimpleOS images may include BlueZ as an explicit distribution feature. When
zsh or Fish is the login shell, the installer writes the same
shell setup to `~/.zshrc` or `~/.config/fish/conf.d/scriptorium.fish`, using the
shell's native PATH setup:

```sh
alias words='simplewords'
alias blue='simpleblue'
alias files='simplefiles'
alias browse='simplebrowse'
alias flac='simpleflac'
alias radio='simpleradio'
alias pod='simplepod'
alias vis='simplevis'
alias clock='simpleclock'
alias check='simplecheck'
alias trident='simpletrident'
alias cal='simplecal'
alias stats='simplestats'
alias ver='simplever'
alias game='simplegame'
alias pdf='simplepdf'
alias news='simplenews'
alias mail='simplemail'
alias net='simplenet'
alias serve='simpleserve'
alias suite-uninstall='simplesuite-uninstall'
```

## SimpleTrident

Run `simpletrident` or its `trident` alias after installing or repairing a
Trident machine. Its role-aware ncurses dashboard verifies:

- **SimpleServe / intranet:** both binaries, the configured client/server role,
  the persistent service, the live daemon control socket, managed NFS mounts,
  and—on servers—active NFS/SMB publishing, phone-compatible Linux NFS export
  policy, and removable-drive reconciliation. A packaged SimpleSuite source
  snapshot supplies the system verifier when no working checkout is present.
- **Tailscale / encrypted extranet:** the client and persistent daemon, a live
  `100.64.0.0/10` tailnet address, SimpleServe's active NFS/SMB publishing
  bridge on servers, and a live NFS reachability probe for every remembered
  client mount's Tailscale fallback.
- **OpenSSH / client + daemon:** verifies that both the outbound `ssh` client
  and inbound `sshd` daemon binary are installed on client and server roles.
- **Caddy website / local web origin:** the website checkout, installed Caddy
  configuration, Caddy/store services, local HTTP health, private-edition
  blocking, fulfillment/recovery-mail configuration, store health, blog sync,
  and the Cloudflare tunnel service on a server. Missing recovery mail or
  another supporting-service failure is `PARTIAL` when the local origin still
  works. The installed Caddy configuration is authoritative at runtime; a
  missing Scriptorium source snapshot only skips the optional provenance
  comparison and does not downgrade an otherwise healthy site. Packaged source
  snapshots are used as a fallback when available. This server-only prong is
  omitted entirely in client mode, so clients neither run nor recommend Caddy
  repair. The public Internet route remains outside this bounded local check.

Use Up/Down to select a category and Enter or `D` to open its evidence. A
failed category also shows repair commands and service-log commands. Press `R`
to rerun all checks and `Q` to quit. For scripts or remote troubleshooting,
`simpletrident --check` prints the same `OK`, `PARTIAL`, `DOWN`, or `UNKNOWN`
results and exits nonzero unless every category applicable to the detected
role is `OK`.

## SimpleCheck

Run `simplecheck` or its `check` alias to review branch, ahead/behind, and
working-tree status for `~/writing`, `~/scriptorium`, `~/simplesuite`, and
`~/website` in one screen. Startup and normal refreshes are local; network
access occurs only for an explicit check, pull, or push. Local refreshes use
one bounded status snapshot per repository and run all four snapshots
concurrently.

- `R`: refresh local status.
- `C`: fetch and prune each repository's remote-tracking refs, then recalculate
  ahead/behind counts. The four fetches run concurrently, so one slow remote
  does not make the other repositories wait in series.
- `L`: check remotes, then concurrently rebase repositories that are behind
  onto their freshly fetched upstreams using autostash.
- `P`: check remotes and refuse to continue if any repository is behind. If a
  working tree is dirty, SimpleCheck asks once for a commit message, runs
  `git add -A`, commits each dirty repository with that message, and pushes all
  four repositories concurrently.
- Up/Down or `j`/`k`: scroll; `Q`: quit. During a Git command, `Q`, Esc, or
  Ctrl-C cancels it with a 25 ms input polling ceiling. Local status snapshots
  have a 10-second timeout; network and mutating Git commands have a 45-second
  timeout.
- In the commit-message prompt, Left/Right and Home/End move the cursor;
  Backspace and Delete edit on either side of it.

Review every displayed change before pressing `P`: `git add -A` includes
tracked changes, deletions, and untracked files. Completion messages disappear
automatically, so the next command takes effect immediately.

## Mail and Credentials

Scriptorium configures Git with:

```text
credential.helper=store
pull.rebase=true
rebase.autoStash=true
```

During install it offers to store a GitHub username and personal access token.
Leave the username blank to skip authentication; public clones still work.
When provided, the token is checked against GitHub when the API is reachable
and stored by Git's credential store in `~/.git-credentials` with mode `600`.

If you choose Gmail setup, `scripts/setup-simplemail-gmail.sh` writes Gmail
IMAP/SMTP settings for `mbsync` and `msmtp`, creates local Maildir folders under
`~/.local/share/simplemail/mail`, and writes:

```text
~/.mbsyncrc
~/.msmtprc
~/.config/simplemail/config
```

The Gmail app password is stored in those local mail config files. The files
are chmodded to `600`, but they are still plaintext local secrets.

To disconnect the account from GitHub without deleting the four repositories
or their files, run:

```sh
./remove-github-connection.sh
```

This intentionally removes global and repository-local Git identity and
GitHub credential-helper settings, GitHub entries in common credential files
and supported keyrings, GitHub CLI authentication files, and GitHub SSH
`known_hosts` entries. Embedded credentials are stripped from GitHub remote
URLs while ordinary unauthenticated URLs are retained. Close the terminal
afterward to discard any GitHub token inherited by that shell.

## SimpleCal Reminders

After SimpleSuite is built, Scriptorium runs:

```sh
simplecal --install-reminders
```

SimpleCal prefers a persistent systemd user service:

```text
~/.config/systemd/user/simplecal-reminders.service
```

If systemd user services are unavailable, it falls back to a cron entry that
runs `simplecal --check-reminders` once per minute.

## Safety

Before linking dotfiles, existing targets are moved into:

```text
~/.scriptorium-backups/YYYYMMDD-HHMMSS-PID/
```

The main installer also prepares a temporary rollback copy of Git config,
SimpleSuite files, linked dotfiles, mail config, SimpleCal config/state, and
installed binaries. If installation fails, it asks whether to roll those user
files back. Package-manager changes are not rolled back.
APT source repairs and AppArmor profile changes are system-level changes and
are not included in that rollback either. The enabled SimpleServe system
service is likewise outside the user-file rollback; rerunning the installer
safely updates and re-verifies it, while `simplesuite-uninstall` removes it and
its managed NFS/SMB configuration.

Tailscale package installation and tailnet enrollment are also outside the
user-file rollback. `burn.sh` deliberately does not log the machine out of
Tailscale, delete its node identity, or remove the package because other
services may rely on that connection. Use Tailscale's own logout/package
removal flow when that destructive action is actually intended.

This repo includes destructive cleanup scripts:

- `burn-writing.sh` removes the writing checkout and related writing
  credentials after confirmation.
- `burn.sh` invokes SimpleSuite's native burn, then removes any remaining
  Scriptorium-managed binaries, configs, typewriter/alarm assets, SimpleCal
  reminder services, SimpleMail setup, the privileged FreeBSD SimpleFiles
  helper, the SimpleServe system service and state, rollback backups, and both
  source checkouts after confirmation.

The single `BURN` confirmation authorizes both cleanup layers; there is no
second SimpleSuite prompt.

Do not run either script unless you intend that cleanup.

Scriptorium installs the OpenSSH programs but does not manage SSH keys,
`sshd_config`, or writing project contents during normal installation. It can
store GitHub and Gmail credentials locally if you choose those setup paths.
The managed SimpleCal dotfiles may include local calendar/reminder data, so
treat this checkout as private unless that data has been removed.
