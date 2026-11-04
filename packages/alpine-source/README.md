# Alpine source dependencies

Stable Alpine repositories currently lack Calibre and libsidplayfp. The
installer builds native APKs for these dependencies without enabling edge or
testing repositories. Source archives and recipe patches have SHA-512 checksums.

Calibre 9.16.0, py3-apsw 3.53.4.0, py3-html5-parser 0.5.0 and their patches are
the official Alpine aports recipes at commit
`f223d8d0d1a43fb02d57c33c52f999eb7197bd54`, under `testing/`:
https://github.com/alpinelinux/aports/tree/f223d8d0d1a43fb02d57c33c52f999eb7197bd54/testing
The Calibre recipe adds stable podofo-dev and retains the upstream PDF extension
instead of applying Alpine's disable-podofo patch. The local recipe revision is
9.16.0-r2.
Their upstream licenses and contributor notices remain in the recipes.

libsidplayfp 2.6.0 uses its upstream release archive. Its SHA-256 is also
recorded in Ubuntu's signed `libsidplayfp_2.6.0-1.dsc` source metadata:
`cc6bb9418ad3f64772c54c011552b113f8ef82f9820d74d4c2fed5976d4905e9`.

Builds use a private signing key and a temporary APK trust directory containing
the system's existing public keys plus this build key. They do not add a
repository or a key to the system trust store. Installed files are managed by
APK. Build outputs and downloaded sources stay under `build/alpine-source/`.
