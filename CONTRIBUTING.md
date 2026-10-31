# Contributing to vhosty

## What vhosty is for

vhosty makes folders into private HTTPS sites on your tailnet, with the PHP
versions and settings they need, on a machine that's always on. That's the line
for what goes in.

**The core**, `bin/vhosty`:
- folders to sites: parking, links, the generated Caddyfile, the certificate and
  DNS record, the port route for dev servers
- PHP: versions, per-site pins and settings, extensions, the `php` command
- what keeps that working: `doctor`, `update`, logs, `prune`, error pages
- Docker services, as a thin layer over `docker compose` (start, status, backup
  and restore), not a container platform

**Around the core**, `scripts/` and `docs/`: ways to get a machine ready for
vhosty, like `box-setup.sh` for a fresh VM and `instabox.sh` for InstaBox. They
are optional. The core never needs them, and they only use vhosty through its
commands.

**Not planned:**
- hosting for several users on one machine (give each developer a box: see
  [docs/instabox.md](docs/instabox.md))
- a web UI or dashboard
- a long-running vhosty process of its own: Caddy, PHP-FPM, systemd and launchd
  do the running
- managing things vhosty didn't make (your own nginx, databases installed
  outside Docker)

When a change doesn't fit, a script in `scripts/` or a page in `docs/` is often
the better home.

## How the code is kept

- One bash file, compatible with the bash 3.2 that ships with macOS: no
  associative arrays, `mapfile`, `${x,,}` or other bash 4 features. CI runs the
  tests with macOS's own bash.
- `set -euo pipefail` throughout. Watch for `[ cond ] && cmd` as the last line of
  a function or loop (it fails when `cond` is false), and for `$(...)` hiding a
  `die` or losing variables set inside it.
- Everything the user can name (folders, settings) is data: write it into shell
  files with `printf %q`, into the Caddyfile only after `check_folder`, and never
  through `eval`.
- Secrets stay off command lines (curl reads headers with `-K -`).
- Messages say what happened and what to run next.

## Tests

```bash
bats tests/                      # bats-core 1.x
shellcheck --severity=warning bin/vhosty install.sh scripts/*.sh tests/helpers.bash
```

The tests run in a scratch home with a fake `tailscale`, so they don't touch your
setup; `tests/helpers.bash` has the helpers (`vh` runs one of vhosty's functions
with its real shell options). `tests/caddy.bats` runs the generated Caddyfile in a
real Caddy with the DNS plugins (`VHOSTY_TEST_CADDY`, or the one vhosty
installed), and is skipped without one. Add a test with every fix: one that fails
without it.

## Releases

1. Bump `VHOSTY_VERSION` in `bin/vhosty` in a commit titled `vhosty X.Y.Z`.
2. When CI is green on that commit, tag it `vX.Y.Z` and publish a GitHub release
   with notes. A workflow attaches `SHA256SUMS`, which `vhosty update self` and
   `install.sh` check.
