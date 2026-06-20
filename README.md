# Scriptorium

A reproducible command-line writing environment.

It installs the core Scriptorium programs, installs SimpleSuite dependencies, clones/builds SimpleSuite, then links only the dotfiles that actually exist as config files.

## Included programs

- simplewords
- simplefiles
- simpleflac
- simpleradio
- simplepod
- simplevis
- simplepdf
- simpleclock
- simplestats
- simplever
- simplegame
- neomutt/mutt
- newsboat
- calcurse
- links
- git
- mpv

## Dotfiles currently managed

- `~/.muttrc`
- `~/.mutt/`
- `~/.newsboat/config`
- `~/.newsboat/urls`
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
