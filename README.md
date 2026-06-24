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
- simplemail + mbsync + msmtp
- calcurse
- links
- git
- mpv

## Dotfiles currently managed

- `~/.config/calcurse/`
- `~/.links/`
- `~/.config/simplefiles/config`

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

This installer does not store mail passwords, API keys, SSH keys, or private writing manuscripts.
