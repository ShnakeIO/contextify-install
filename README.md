# Contextify — installer

Install script and released builds for [Contextify](https://contextifyai.com),
a drop-in proxy that cuts what you pay Anthropic.

```sh
curl -fsSL https://contextifyai.com/install.sh | bash
```

macOS and Linux. Windows via WSL. Requires Node.js 22 or newer.

The installer never uses `sudo` and never writes outside its install directory
(`~/.contextify` by default). `--dry-run` prints exactly what it will do and
exits without changing anything.

Piping any script to a shell is a real trust decision. To read it first:

```sh
curl -fsSL https://contextifyai.com/install.sh -o install.sh
less install.sh
bash install.sh
```

Each release publishes a `.sha256` beside the tarball, and the installer
verifies it before extracting anything.

This repository holds only the installer and the built release. Contextify
itself is proprietary; see [LICENSE](LICENSE).
