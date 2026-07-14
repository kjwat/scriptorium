# Scriptorium

A reproducible command-line writing environment for SimpleSuite and related
terminal tools.

`install.sh` installs package dependencies, clones or updates
[SimpleSuite](https://github.com/kjwat/simplesuite), builds it, installs the
binaries into `~/.local/bin`, links Scriptorium-managed dotfiles, and prepares
the local shell environment.

## First Run

```sh
git clone https://github.com/kjwat/scriptorium.git
cd scriptorium
./install.sh
```

Run this from an interactive shell. Linux package installation needs either a
root shell or a working `sudo`; macOS needs Homebrew and the Apple Command Line
Tools. A base Alpine installation bootstraps Bash automatically. Bash users
receive `~/.bashrc` setup, and zsh users receive matching `~/.zshrc` setup.
When an interactive installation finishes, it starts a configured shell so
commands such as `words` and `simplewords` work immediately. A noninteractive
installation instead prints the shell file to source before using the commands.

## What It Installs

SimpleSuite programs:

- `simplebrowse`
- `simplewords`
- `simplefiles`
- `simplemail`
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

Scriptorium also builds and installs `simplecheck`, its ncurses dashboard for
the `~/writing`, `~/scriptorium`, and `~/simplesuite` Git repositories.

Runtime and workflow tools installed by the package script include, depending
on platform availability:

- build tools, `pkg-config`, ncurses, GIO/GLib, libcurl, and OpenSSL headers
- Python GI, GTK 3 introspection, and WebKit2GTK 4.1 for SimpleBrowse v4
  JavaScript mode on supported Linux families
- `git`, `mpv`, `links`, `fzf`, `calcurse`
- `isync`/`mbsync` and `msmtp` for SimpleMail
- `pdftotext`/poppler and `pandoc` for SimplePDF
- `zip`, `unzip`, `tar`, `file`, `less`, `curl`, `ca-certificates`, `rsync`
- `util-linux`, UDisks, and cron tooling for SimpleFiles drives and SimpleCal
  reminder fallback
- clipboard, desktop-open, trash, and audio helper packages where available

Supported package targets are current Debian/Ubuntu, Arch-family distributions,
Fedora, Alpine (with `main` and `community`), Void, openSUSE Tumbleweed, and
macOS/Homebrew. RHEL/CentOS-family releases, SLES, and openSUSE Leap do not
consistently carry the complete feature set in their default repositories; the
installer stops before changing packages unless the dependencies were already
provisioned. If platform detection is unknown, `scripts/install-packages.sh`
asks for a package family and stores the choice in
`~/.config/simplesuite/family`.

Use a currently supported distro release with its official repositories
enabled. In particular, full SimpleBrowse JavaScript mode needs WebKitGTK 4.1;
if an older release does not provide a required package, installation stops
with repository/release guidance instead of leaving a partially working build.

On macOS, Scriptorium supplies a small build-only Darwin compatibility layer
for the BSD interfaces hidden by SimpleSuite's strict POSIX feature settings
and for the `clock_nanosleep` interface absent from Apple libc. Homebrew's
WebKitGTK formula is Linux-only, so SimpleBrowse's static reader works there but
its WebKit/JavaScript mode is not installed. The installer skips that
unavailable feature instead of failing the whole installation.

Some runtime integrations remain Linux-specific: use Finder or `diskutil`
instead of SimpleFiles' guarded `:unmount`; SimpleWords and SimpleBrowse use
their internal clipboards rather than the Wayland/X11 system-clipboard bridge;
SimpleMail's attachment-open shortcut expects `xdg-open`; and SimpleStats'
Linux hardware metrics are not meaningful on macOS.

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
--ff-only`. The SimpleSuite build installs binaries to `~/.local/bin`,
including `simplesuite-uninstall`. Shared audio assets are installed under:

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

`~/.bashrc` receives `~/.local/bin` on PATH and these aliases. When zsh or Fish
is the login shell, the installer also writes the same setup to `~/.zshrc` or
`~/.config/fish/conf.d/scriptorium.fish`, using the shell's native PATH setup:

```sh
alias words='simplewords'
alias files='simplefiles'
alias browse='simplebrowse'
alias flac='simpleflac'
alias radio='simpleradio'
alias pod='simplepod'
alias vis='simplevis'
alias clock='simpleclock'
alias check='simplecheck'
alias cal='simplecal'
alias stats='simplestats'
alias ver='simplever'
alias game='simplegame'
alias pdf='simplepdf'
alias news='simplenews'
alias mail='simplemail'
```

## SimpleCheck

Run `simplecheck` or its `check` alias to review branch, ahead/behind, and
working-tree status for `~/writing`, `~/scriptorium`, and `~/simplesuite` in
one screen. Startup and normal refreshes are local; network access occurs only
for an explicit check, pull, or push.

- `R`: refresh local status.
- `C`: fetch and prune each repository's remote-tracking refs, then recalculate
  ahead/behind counts.
- `L`: check remotes, then pull repositories that are behind using
  `git pull --rebase --autostash`.
- `P`: check remotes and refuse to continue if any repository is behind. If a
  working tree is dirty, SimpleCheck asks once for a commit message, runs
  `git add -A`, commits each dirty repository with that message, and pushes all
  three repositories.
- Up/Down or `j`/`k`: scroll; `Q`: quit. During a Git command, `Q` or Esc
  cancels it; commands also have a 45-second timeout.

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

To disconnect the account from GitHub without deleting the three repositories
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
are not included in that rollback either.

This repo includes destructive cleanup scripts:

- `burn-writing.sh` removes the writing checkout and related writing
  credentials after confirmation.
- `burn.sh` invokes SimpleSuite's native burn, then removes any remaining
  Scriptorium-managed binaries, configs, typewriter/alarm assets, SimpleCal
  reminder services, SimpleMail setup, rollback backups, and both source
  checkouts after confirmation.

The single `BURN` confirmation authorizes both cleanup layers; there is no
second SimpleSuite prompt.

Do not run either script unless you intend that cleanup.

Scriptorium does not manage SSH keys or writing project contents during normal
installation, but it can store GitHub and Gmail credentials locally if you
choose those setup paths. The managed SimpleCal dotfiles may include local
calendar/reminder data, so treat this checkout as private unless that data has
been removed.
