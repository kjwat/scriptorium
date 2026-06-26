# Scriptorium

A reproducible command-line writing environment.

It installs the core Scriptorium programs, installs [Simplesuite](https://github.com/kjwat/simplesuite) and its dependencies, builds SimpleSuite, and then links only dotfiles that exist as configuration files.

## Included programs

- simplewords
- simplefiles
- simpleflac
- simpleradio
- simplepod
- simplenews
- simplevis
- simplepdf
- simpleclock
- simplestats
- simplever
- simplegame
- simplemail (+ mbsync + msmtp)
- simplecal
- links
- git
- mpv

## Dotfiles currently managed

- `~/.config/calcurse/`
- `~/.links/`
- `~/.config/simplefiles/config`
- `~/.config/simplenews/config`
- `~/.config/simplenews/urls`

SimpleCal stores its calendar in a user-selected data directory on first launch (default: `~/.config/simplecal`). Scriptorium configures SimpleCal to use its portable calendar directory automatically during installation and installs the background reminder service.

Most SimpleSuite tools do not currently have config files. They are installed as programs, not linked as dotfiles.

## First run

```sh
git clone https://github.com/kjwat/scriptorium.git
cd scriptorium
./install.sh
```

## Safety

Existing config files are backed up before links are created.

Backups go to:

```text
~/.scriptorium-backups/YYYYMMDD-HHMMSS/
```

This installer does not store mail passwords, API keys, SSH keys, private writing manuscripts, or calendar data outside the directory you choose for SimpleCal.
