# Installation policy

All SimpleSuite and Scriptorium programs install in `/usr/local/bin`, with
system daemons in `/usr/local/sbin` and suite assets in
`/usr/local/share/simplesuite`. `~/.local/bin` is for unrelated personal tools.

Never install or fall back to installing these programs under `~/.local`.
When administrator authentication is needed, obtain it for the system install.
After verifying a system replacement, remove its old user-local copy and any
owned short-command symlink. Keep shell aliases pointing to canonical programs.
Temporary staging destinations and isolated test prefixes are allowed.
