# vhosty on macOS with Homebrew PHP: design

Status: implemented on the `macos-brew` branch (from `herd-backend`), tested against a
fake Homebrew and fake `tailscale` (`tests/macos.bats`), not yet on a real Mac. The
"To verify on the Mac" list below still stands.

Two changes to vhosty's own macOS mode (`VHOSTY_BACKEND=vhosty`), plus closing
the gaps between Linux and macOS. The Herd backend keeps working as it does, and
picks up the shared Tailscale Serve code.

1. **PHP from Homebrew** (`shivammathur/php`) instead of static PHP-FPM builds.
   vhosty still runs one PHP-FPM per version itself, from its launchd daemons,
   with its own `php-fpm.conf`; only the binaries change.
2. **Caddy behind Tailscale Serve**, as with Herd. Caddy can't listen on
   `100.x.y.z:443` or `127.0.0.1:443` as a normal user: since Mojave, macOS lets an
   ordinary user listen below 1024 only on every address at once. Today's macOS
   mode generates exactly that bind, so it fails the way the Herd backend did.

## Why Homebrew PHP

The static builds (static-php.dev) have a fixed set of extensions. There's no
`pdo_pgsql`, nothing can be added (no `phpize`, no pecl, no shared extensions),
and there's no CLI per version, so `php artisan` and composer run some other PHP.
On Linux, apt gives all three. Homebrew is the macOS equivalent, and
[shivammathur/php](https://github.com/shivammathur/homebrew-php) has every
version side by side, like Ondřej Surý's apt repo:

| | Linux (apt, sury) | macOS (Homebrew, shivammathur) |
|---|---|---|
| Install a version | `apt install php8.4-fpm php8.4-cli …` | `brew install shivammathur/php/php@8.4` |
| FPM binary | `/usr/sbin/php-fpm8.4` | `$BREW/opt/php@8.4/sbin/php-fpm` |
| CLI | `/usr/bin/php8.4` | `$BREW/opt/php@8.4/bin/php` |
| php.ini, conf.d | `/etc/php/8.4/{cli,fpm}/` | `$BREW/etc/php/8.4/`, `…/conf.d` |
| Extra extensions | `apt install php8.4-redis` | `brew install shivammathur/extensions/redis@8.4`, else that version's `pecl` |

`$BREW` is `/opt/homebrew` (Apple Silicon) or `/usr/local` (Intel).

### Facts this relies on (checked against the taps on 2026-11-01)

- Versions up to 8.4 (and the nightly 8.6, 8.7) are real `php@X.Y` formulas,
  keg-only, at `$BREW/opt/php@X.Y`. **The newest stable (8.5) is the plain `php`
  formula**: `php@8.5` is only an alias, so its keg is `$BREW/opt/php`. vhosty
  reads that keg's version from where `opt/php` points (`../Cellar/php/8.5.12`).
  When 8.6 becomes stable, `opt/php` moves to 8.6 and `php@8.5` becomes a real
  formula. Sites on 8.5 lose their PHP until `vhosty php install 8.5` (doctor
  says so), the same as removing an apt package.
- Compiled in, in 8.4 and 8.5: pdo_pgsql, pgsql, pdo_sqlite, sqlite3, pdo_mysql,
  mysqli, intl, gd, zip, bcmath, soap, sodium, pcntl, mbstring, opcache. That
  covers `PHP_PACKAGES` on Linux except `redis` and `igbinary`, which come from
  shivammathur/extensions.
- shivammathur/extensions: `<ext>@<X.Y>` formulas (redis, igbinary, imagick,
  xdebug, mongodb, protobuf, grpc, pcov, swoole, apcu, memcached, …). Each writes
  `$BREW/etc/php/X.Y/conf.d/20-<ext>.ini`, which PHP-FPM reads. vhosty's
  `--fpm-config` only replaces `php-fpm.conf`, not php.ini, so it reads it too.
- The README asks for `brew trust shivammathur/extensions` after tapping it, on
  Homebrew versions that have `brew trust`.

**To verify on the Mac:** that `pecl` sits in each keg's `bin/` and writes its
`extension=` line where FPM reads it; that `brew install` doesn't start an FPM
of its own (`brew services`, which would take 127.0.0.1:9000, RustFS's port).

## PHP: how it fits the code

Nothing about pools, sockets, ini layering, isolation or the shim's logic changes.
Only where the binaries come from:

- **`brew_prefix`**: `$VHOSTY_BREW_PREFIX`, else `/opt/homebrew` or `/usr/local`,
  whichever has `bin/brew`. The override is for tests.
- **`brew_php_dir X.Y`**: `$BREW/opt/php@X.Y` if it has `sbin/php-fpm`; else
  `$BREW/opt/php` if that keg is X.Y. Any `php@X.Y` keg counts, from homebrew-core
  or shivammathur.
- **`php_installed_versions`** (macOS): the Homebrew versions, plus any old static
  build still in `~/.vhosty/bin/php-fpm-X.Y` (see Migration).
- **`fpm_bin X.Y`** (macOS): Homebrew's `sbin/php-fpm`, else the old static build.
  The launchd plists keep the full path. `opt/` paths survive `brew upgrade`.
- **`php_cli X.Y`** (both): `/usr/bin/phpX.Y` on Linux, Homebrew's `bin/php` on
  macOS. Used by the extension checks (`php_bin_for`), and by the shim.
- **CLI shim**: today it looks for `/usr/bin/php$v`, `/usr/local/bin/php$v`, then
  `~/.vhosty/bin/php-$v`. On macOS it also looks for `$BREW/opt/php@$v/bin/php`,
  and `write_shim` adds the version of `opt/php` (known when it's generated).
- **`brew_link_clis`** links `~/.vhosty/bin/php-X.Y` → each Homebrew version's
  CLI on `rebuild`, so `php-8.4 -v` works on a Mac like `php8.4` does on Linux.
  (Completion globs those links.)

### Commands

| Command | Linux | macOS |
|---|---|---|
| `vhosty php install 8.4` | apt: `PHP_PACKAGES` and declared extensions, distro FPM disabled | `brew tap shivammathur/php`, `brew install shivammathur/php/php@8.4`, then redis, igbinary and declared extensions from shivammathur/extensions. Removes an old static build of 8.4 |
| `vhosty ext install X --php 8.4` | apt `php8.4-X` | `shivammathur/extensions/X@8.4` if it exists, else `pecl install X` with that version's pecl. Restarts that FPM |
| `vhosty ext require`, `doctor --fix` | installs missing extensions | same, now on macOS too |
| `vhosty update php [8.x]` | was "use apt"; now `apt-get install --only-upgrade` of that version's installed packages | was a static download; now `brew upgrade` of that version's formula and its extension formulas |
| `vhosty update` | Caddy, PHP in use, vhosty | same |
| `vhosty doctor` | unchanged | also: an old static build still in use, PHP from Homebrew run by `brew services` (it takes 127.0.0.1:9000) |

`brew` runs as you, never with sudo: Homebrew refuses root. Setup on macOS
requires Homebrew when PHP is on, and says how to get it (https://brew.sh), or to
use `--no-php`.

### Migration from the static builds

Existing Macs have `~/.vhosty/bin/php-fpm-X.Y` (regular files; Homebrew's never
live there). They keep working until moved, so `vhosty update self` (which runs
`rebuild`) can't break a running box:

- `fpm_bin` falls back to the static build when Homebrew doesn't have that version.
- `vhosty setup` installs each version in use from Homebrew, then removes the
  static builds.
- `vhosty php install X.Y` does the same for one version.
- `doctor` flags a static build still in use ("can't add extensions; move it:
  vhosty php install X.Y"). `ext install` on a static version says the same.
- `PHP_DOWNLOADS`, `php_fpm_file` and the download code go. `migrate_php_fpm`
  (0.1's unversioned `bin/php-fpm`) stays, since it feeds the same fallback.

## Listening: Tailscale Serve on every Mac

`uses_serve` = macOS (either backend). The Herd code's `herd_serve_*` become
`serve_*`, used by both backends; Linux is unchanged (Caddy binds the Tailscale
IP and localhost on 80/443, with `setcap`). *Later: Linux moved behind Serve too,
with the PROXY header below, so every platform listens the same way.*

On macOS Caddy listens on localhost only, on high ports, and Serve forwards the
tailnet's ports to it as plain TCP. TLS still ends at Caddy, with the wildcard
certificate:

```
tailnet :443  →  tailscale serve --tcp=443  →  127.0.0.1:48443 (Caddy, https_port)
tailnet :80   →  tailscale serve --tcp=80   →  127.0.0.1:48080 (Caddy, http_port: redirect to https)
```

```caddyfile
{
	default_bind 127.0.0.1
	http_port 48080
	https_port 48443
	auto_https disable_redirects   # Caddy's own would point at :48443
}
http://*.yourdomain.dev {
	redir https://{host}{uri} permanent
}
```

Port 80 is new, for both macOS backends. It brings back what Linux has: typing
`escrow.yourdomain.dev` without `https://` works. Settings:
`VHOSTY_SERVE_PORT` (48443; `VHOSTY_HERD_PORT` still read) and
`VHOSTY_SERVE_HTTP_PORT` (48080).

Effects:
- Setup on macOS no longer needs ports 80 and 443 free. Herd, Valet or anything
  else can keep them, even in vhosty's own mode. Setup checks 48443 instead.
- The Caddyfile no longer depends on the Tailscale IP on macOS, so the "Tailscale
  address changed" drift check and `dns sync`'s rebuild are Linux-only.
- `setup`, `rebuild` and `doctor --fix` turn Serve on; `doctor` and `status` check
  it; `uninstall` removes only vhosty's two forwards. Anything else on Serve's 80
  or 443 is replaced only after asking, as now.
- Serve must be enabled on the tailnet. Setup prints Tailscale's link when it isn't.

## Parity: what stays different, and why

| | Linux | macOS | |
|---|---|---|---|
| Services | systemd user units, no sudo | launchd daemons (sudo to manage) | Only daemons start before login on macOS |
| Listening | localhost high ports, Serve forwards 80/443 | same | *Was:* Linux bound the Tailscale IP's 80/443 (setcap); now the same everywhere |
| Client address in PHP | the tailnet device's IP | same | Serve's PROXY header (`--proxy-protocol=2`) |
| Log rotation | `vhosty-logs.timer`, daily | **new:** `link.vhosty.logs`, a launchd daemon running `vhosty logs rotate` daily (was: only when services are set up) | |
| PHP source | apt | Homebrew | |
| Herd backend | n/a | `--herd` | Herd is macOS-only |

Everything else (parking, links, pins, ini, the shim, extension checks and
installs, Docker services, doctor, update, prune, error pages) behaves the same.

## Tests

The tests run on Linux and macOS CI, so the macOS paths are tested by setting
`PLATFORM=macos` inside `vh` and pointing `VHOSTY_BREW_PREFIX` at a fake Homebrew:

- `opt/php@8.4/{sbin/php-fpm,bin/php}` and `opt/php → ../Cellar/php/8.5.1` as
  shell stubs; a `brew` stub that logs its arguments.
- Versions found (including `opt/php`'s), static fallback and Homebrew winning,
  `fpm_bin`, the shim finding the version's CLI, the `php-X.Y` links.
- `php install` and `ext install` commands sent to brew (tap formula vs pecl).
- The macOS Caddyfile: bind, ports, the redirect block; valid in a real Caddy.
- Serve on/off for both ports, through the existing fake `tailscale`.
- The logs plist.

## Follow-ups (not in this change)

- **Client addresses:** Serve has `--proxy-protocol=2` for TCP forwards, and
  Caddy can read it (`listener_wrappers { proxy_protocol … }`). Tailscale's docs
  only show it with `--tls-terminated-tcp`, so try it on the Mac first. If it
  works with `--tcp`, PHP would see the real tailnet address again, as on Linux.
  *Done: it works with `--tcp` (checked on Linux, Tailscale 1.104), and vhosty
  now uses it on every platform.*
