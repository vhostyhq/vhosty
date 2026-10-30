# vhosty on Linux: design

Status: draft for review (2026-10-29). Linux is the priority; macOS keeps working as it does today
and picks up new features only where they're cheap.

## Principles

- **Site settings live in `~/.vhosty`, never in project folders.** Version pins, ini overrides and
  links are vhosty's config, so repos stay clean.
- **No sudo for day-to-day use.** Only `setup` (one-time: linger, port capability) and
  `php install` (apt) need it.
- **Services keep their standard ports.** PHP-FPM listens on Unix sockets, so it takes no TCP
  port. 9000 goes back to RustFS.
- Stays a single bash file, still bash 3.2 compatible (no associative arrays), so macOS keeps working.

## Files

```
~/.vhosty/
├── config                 global settings (shell variables, as today)
├── php.ini                global ini settings for every PHP version, web and CLI
├── sites/<name>.conf      one file per configured site (link, pin, ini overrides)
├── .env                   Cloudflare token (600)
├── bin/                   vhosty, caddy, php (shim)
├── Caddyfile              generated
├── php/<v>/php-fpm.conf   generated, one FPM master per PHP version
├── run/                   sockets and pid files
└── logs/
~/.config/systemd/user/vhosty-caddy.service
~/.config/systemd/user/vhosty-php@.service      template: vhosty-php@8.5, vhosty-php@8.4
```

### `config`

```bash
VHOSTY_DOMAIN="vhosty.link"
VHOSTY_PARKED="/home/remote/Dev"          # colon-separated, several allowed (already supported)
VHOSTY_PHP="on"
VHOSTY_PHP_DEFAULT="8.5"                   # replaces VHOSTY_FPM_PORT
VHOSTY_SERVICES_DIR="/home/remote/Dev/services"   # docker compose project for `vhosty services`
```

### `php.ini` (global)

Plain ini syntax, applied to every PHP version, for both web requests (FPM) and the CLI (the shim):

```ini
memory_limit = -1
upload_max_filesize = 256M
post_max_size = 256M
```

### `sites/<name>.conf`

Created only when a site needs something beyond the defaults. `<name>` is the hostname label
(`kudos` → `https://kudos.vhosty.link`).

```bash
SITE_PATH="/home/remote/Dev/kudos"   # set by `link`; parked sites store their resolved path too
SITE_LINKED="no"                      # yes = served from SITE_PATH even if not in a parked folder
SITE_PHP="8.4"                        # pin; empty = VHOSTY_PHP_DEFAULT
SITE_INI="memory_limit=2G
max_execution_time=300"               # newline-separated key=value overrides
```

## How requests are served

Caddy matches in this order:

1. `<port>.domain` → `localhost:<port>` (unchanged).
2. **Configured sites** (linked, pinned, or with ini overrides): an exact `host` matcher per site,
   served from `SITE_PATH`, sent to that site's FPM pool.
3. **Parked folders**: the existing wildcard file matchers, sent to the default version's pool.
4. 404.

A site counts as PHP if it has `public/index.php`, or static if it has `index.html`, as today.

## PHP-FPM

- Packages come from apt (`packages.sury.org/php`). The distro `phpX.Y-fpm` services stay disabled.
- **One FPM master per installed version**, run as the user by `vhosty-php@X.Y`.
- **Pools inside each master:**
  - `default`: socket `run/php-X.Y.sock`, used by parked sites on that version.
  - `site-<name>`: socket `run/site-<name>.sock`, one per site with ini overrides.
    A separate pool, not `PHP_VALUE`, because values set through `PHP_VALUE` stick to the FPM
    worker and leak into the next site it serves. Pools use `pm = ondemand`, so idle ones cost nothing.
- **ini layering:** the distro `php.ini` and conf.d come first, then `~/.vhosty/php.ini`
  (as `php_value[...]` in every pool), then the site's `SITE_INI` (only in its own pool).
- Pinned sites without ini overrides share the default pool of their pinned version.

## CLI shim (`~/.vhosty/bin/php`)

Already on PATH via `.zshrc`, ahead of `/usr/bin`. On each call it:

1. walks up from `$PWD` to find a configured site (its `SITE_PATH`), or a folder directly inside a
   parked directory with a `sites/<name>.conf`;
2. picks the version (`SITE_PHP`, else `VHOSTY_PHP_DEFAULT`);
3. runs `/usr/bin/phpX.Y -d key=value ...`, with `~/.vhosty/php.ini` values first and then
   `SITE_INI`.

`composer` (`#!/usr/bin/env php`) and `php artisan` go through the shim automatically.
`VHOSTY_PHP_VERSION=8.4 php ...` overrides the version for one command.
Adds a few milliseconds per call; no daemons.

## Commands

New or changed (everything else keeps its current behavior):

| Command | What it does |
|---|---|
| `vhosty park [dir]` / `unpark [dir]` / `parked` | Unchanged: serve every folder in dir. Several allowed. |
| `vhosty link [dir] [--name N]` | Serve one folder (default: current) as `N.domain` (default: folder name) |
| `vhosty unlink [name]` / `links` | Remove or list links |
| `vhosty php list` | Installed versions, the default, and running FPMs |
| `vhosty php install <v>` | apt-install `phpX.Y-*` with the standard extensions (sudo), start its FPM |
| `vhosty php default <v>` | Set the default version |
| `vhosty isolate <v> [site]` | Pin a site (default: current folder) |
| `vhosty unisolate [site]` / `isolated` | Remove a pin / list pins |
| `vhosty ini` | Show global and site ini settings for the current folder |
| `vhosty ini set <key> <value> [--global\|--site N]` | Set a value (default: current folder's site; outside one, global) |
| `vhosty ini unset <key> [--global\|--site N]` | Remove a value |
| `vhosty ini edit [--global\|--site N]` | Open the file in `$EDITOR`, then apply |
| `vhosty site [name]` | Everything about one site: path, URL, version, ini, how it's served |
| `vhosty services up\|down\|restart\|status\|logs [svc]\|pull` | `docker compose` for `VHOSTY_SERVICES_DIR` |
| `vhosty start\|stop\|restart [caddy\|php[@v]]` | Now systemd, no sudo |

Any change to sites or ini regenerates the configs and reloads only what's needed: Caddy reloads
gracefully, and FPM masters reload with `systemctl --user reload`, which keeps workers busy with
requests running.

## Services (systemd user units)

- `setup` runs `loginctl enable-linger $USER` once, so the units start at boot without a login.
- Caddy binds 80/443 without root via `setcap cap_net_bind_service=+ep ~/.vhosty/bin/caddy`
  (repeated after `vhosty update caddy`, since replacing the binary drops the capability).
- `Restart=on-failure` and logs in `~/.vhosty/logs`, readable with `vhosty logs` as today
  (`journalctl --user -u vhosty-*` works too).
- macOS keeps launchd.

## Docker helpers

`vhosty services` is a thin wrapper around `docker compose --project-directory $VHOSTY_SERVICES_DIR`.
The compose file stays yours. `vhosty doctor` adds a section that checks every service is up and
bound to `127.0.0.1` only.

## Other Linux changes

- `install.sh` and `setup`: allow Linux. Requirements: `curl`, `jq`, Tailscale, and apt PHP if PHP is on.
- Caddy certificates: `~/.local/share/caddy/certificates`.
- `open` → `xdg-open` when there's a display, otherwise print the URL. `url` → `wl-copy`/`xclip`
  if present.
- `lsof` → `ss -ltnp`. `plutil` → `jq`.

## Migration from the Mac config

`setup` reads the existing `config`. `VHOSTY_FPM_PORT` is dropped (with a note), and `/Users/...`
paths are rewritten to `$HOME`.

## Build order (each step tested on this box before the next)

1. Platform layer: Linux paths, systemd units, setup and install. One PHP version, served end to
   end with a real certificate.
2. Multiple FPM versions, `php` commands, `isolate`, the CLI shim.
3. `php.ini` and per-site ini with dedicated pools.
4. `link`/`unlink`, `site`.
5. `vhosty services`, plus RustFS back on 9000.
6. `doctor`, completions, README, and pushing to `vhostyhq/vhosty`.
