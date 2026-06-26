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

Most SimpleSuite applications do not currently use configuration files. They are installed as programs; only applications with user-editable configuration are managed by Scriptorium.

## First run

```sh
git clone https://github.com/kjwat/scriptorium.git
cd scriptorium
./install.sh
````

## Safety

Existing configuration files are backed up before links are created.

Backups are stored in:

```text
~/.scriptorium-backups/YYYYMMDD-HHMMSS/
```

Scriptorium installs software and manages configuration files. It does not store passwords, SSH keys, API keys, or the contents of your writing projects.
