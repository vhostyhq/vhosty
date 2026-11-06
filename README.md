<p align="center">
  <img src="https://github.com/vhostyhq/.profile/blob/main/profile/vhosty-wordmark.svg" alt="vhosty" width="320">
</p>

# vhosty cli

**Herd for your tailnet.** Every folder becomes a private HTTPS site on your own
domain, reachable from your phone, laptop, or any device on your
[Tailscale](https://tailscale.com) network.

```
~/Sites/myspace    →  https://myspace.yourdomain.dev
~/Sites/geocities  →  https://geocities.yourdomain.dev
localhost:5173     →  https://5173.yourdomain.dev
```

- Real HTTPS: a trusted Let's Encrypt wildcard certificate, with no browser warnings and no local CA to install.
- Private: the sites are reachable only from your tailnet. Nothing is exposed to the internet, and no router ports are opened.
- No per-site setup: drop a folder in, and it's live.
- Several PHP versions side by side, pinned per site, with per-site PHP settings. The `php` command follows the site you're in.
- Built for an always-on dev box, like an old iMac running Linux and your coding agents, that you check from anywhere.

Runs on **Linux** (systemd) and **macOS** (launchd).

## How it works

```
your phone ──tailnet──▶ dev box (100.x.y.z)
                         └─ Tailscale Serve :443 ─▶ Caddy 127.0.0.1:48443   *.yourdomain.dev, wildcard cert
                              ├─ <port>.yourdomain.dev  → localhost:<port>
                              ├─ <site>.yourdomain.dev  → PHP-FPM <version> (site/public/index.php)
                              ├─ <site>.yourdomain.dev  → Laravel Octane on a local port (vhosty octane on)
                              └─ <site>.yourdomain.dev  → static (site/index.html)
```

1. **DNS:** one wildcard record, `*.yourdomain.dev`, points at the machine's Tailscale IP. The name is public, but the IP is only reachable from your tailnet.
2. **Certificates:** Caddy proves it owns the domain with a DNS challenge through your DNS provider's API, so Let's Encrypt never needs to reach the machine.
3. **Routing:** Caddy reads the hostname and serves the matching folder (PHP through PHP-FPM, or static files) or proxies a port. It listens on localhost only, and [Tailscale Serve](https://tailscale.com/kb/1312/serve) passes the tailnet's ports 443 and 80 to it, so nothing is open to your LAN. See [Tailscale Serve](#tailscale-serve).
4. **Services:** Caddy, one PHP-FPM per PHP version in use, and one service for each [Octane](#laravel-octane) site. On Linux they're systemd user services (no sudo to manage them); on macOS, launchd daemons. They start at boot and restart if they crash.

## Requirements

- **[Tailscale](https://tailscale.com/download)** on this machine and on every device you'll browse from.
- **A domain whose DNS is on [Cloudflare](https://cloudflare.com)**, or on another provider vhosty supports (see [DNS providers](#dns-providers)). It can be one you own or a new one, and it doesn't have to be dedicated to vhosty: if its `*` record is already used (say, by staging sites), use a subdomain like `box.example.com`.
- **An API token for it.** For Cloudflare: *Zone → Read* and *DNS → Edit* for that domain, created at dash.cloudflare.com → My Profile → API Tokens with the "Edit zone DNS" template.
- **[Tailscale Serve](https://tailscale.com/kb/1312/serve) enabled on your tailnet.** Setup prints Tailscale's link to enable it if it isn't. Ports 80 and 443 on the machine itself can stay in use (nginx, Apache, Herd, Valet): vhosty doesn't need them. On macOS it can also put Laravel Herd's sites on your tailnet instead (see [With Laravel Herd](#with-laravel-herd-macos)).

**Linux** (tested on Ubuntu 26.04): systemd, `curl`, `jq`, and PHP from apt. Ubuntu
ships one PHP version; for several side by side, add Ondřej Surý's repo
([packages.sury.org/php](https://packages.sury.org/php/README.txt)), then
`vhosty php install 8.4`. Setup asks for your password twice, once each to let
your services run at boot (`loginctl enable-linger`) and to let your account
manage Tailscale Serve (`tailscale set --operator`). Nothing else needs root.

**macOS** 13 (Ventura) or newer, Intel or Apple Silicon, with
[Homebrew](https://brew.sh) for PHP (not needed with `--no-php` or `--herd`).
Starting and stopping services asks for your password (launchd daemons).

vhosty downloads its own Caddy, with your DNS provider's plugin built in.

### DNS providers

| `--dns` | Credentials (`~/.vhosty/.env`) | The `*.domain` record |
|---|---|---|
| `cloudflare` (default) | `CF_API_TOKEN` | vhosty creates it, and updates it with `vhosty dns sync` |
| `digitalocean` | `DO_AUTH_TOKEN` | you create it once |
| `porkbun` | `PORKBUN_API_KEY`, `PORKBUN_API_SECRET_KEY` | you create it once |
| `route53` | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_REGION` | you create it once |
| `custom` | whatever its plugin needs | you create it once |

Setup asks for the credentials (or takes them from the environment) and saves them
in `~/.vhosty/.env`, which Caddy reads. For the providers marked "you create it
once", setup shows the record to add: `*.yourdomain.dev`, type A, pointing at the
machine's Tailscale IP. `vhosty doctor` checks it, and `vhosty dns sync` shows it
again if the IP changes. The certificate itself doesn't need the record; browsers do.

**Any other provider** with a [Caddy DNS plugin](https://github.com/caddy-dns) works
as `custom`. In `~/.vhosty/config`, name the plugin and its Caddyfile line, put its
credentials in `~/.vhosty/.env`, and run `vhosty update caddy`, then `vhosty rebuild`:

```bash
VHOSTY_DNS=custom
VHOSTY_DNS_PLUGIN=github.com/caddy-dns/gandi
VHOSTY_DNS_TLS='dns gandi {env.GANDI_BEARER_TOKEN}'
```

The plugin has to be one Caddy's build server offers (caddyserver.com/download).
Hetzner isn't in the table for that reason: the build server only has its v1
plugin, which uses Hetzner's old DNS API.

## Install

```bash
git clone https://github.com/vhostyhq/vhosty.git
cd vhosty && ./install.sh
vhosty setup
```

Or in one line:

```bash
curl -fsSL https://raw.githubusercontent.com/vhostyhq/vhosty/main/install.sh | bash
```

The one-liner installs the [latest release](https://github.com/vhostyhq/vhosty/releases).
For another, set `VHOSTY_REF` to its tag, or to `main` for changes that aren't released yet:
`curl -fsSL … | VHOSTY_REF=v0.3.0 bash`. A clone installs whatever is checked out
(`git checkout v0.3.0` first for a release).

**On a cloud VM:** one command creates an [InstaBox](https://instabox.sh) machine and
sets it up as a vhosty box, with Tailscale, PHP and Docker services. On any fresh Debian or
Ubuntu VM (a droplet, a Hetzner server), `scripts/box-setup.sh` does the same setup. See
[docs/instabox.md](docs/instabox.md).

`vhosty setup` asks for your domain, token, and the folder to park, then:

- downloads Caddy into `~/.vhosty/bin` (and on macOS installs PHP with Homebrew),
- creates or fixes the `*.domain` DNS record on Cloudflare (DNS only, not proxied), or shows the record to create on other providers,
- generates the Caddyfile and PHP-FPM configs,
- installs and starts the services, and
- waits for the wildcard certificate.

To run it without prompts:

```bash
CF_API_TOKEN=... vhosty setup --domain box.example.com --park ~/Sites --yes
```

The token can also be given with `--token`, but then it's in your shell history and,
while setup runs, visible to other users of the machine. `--yes` won't replace a
`*.domain` record that points somewhere other than a Tailscale address (a staging
server, say); add `--overwrite-dns` if that's what you want.

Add `~/.vhosty/bin` to the front of your `PATH` so `php` follows the site you're
in (see [PHP versions](#php-versions)), and turn on tab completion (zsh):

```bash
export PATH="$HOME/.vhosty/bin:$PATH"
fpath=(~/.vhosty/completions $fpath)   # before compinit
```

## Tailscale Serve

Caddy listens on `127.0.0.1:48443` and `:48080` only, and
[Tailscale Serve](https://tailscale.com/kb/1312/serve) passes the tailnet's ports
443 and 80 to them (`tailscale serve status` shows it). It works the same on Linux
and macOS:

- The connection stays encrypted end to end with vhosty's certificate; Serve only
  forwards it, and port 80 only redirects to `https://`.
- Serve tells Caddy which device is asking (a PROXY protocol header), so PHP sees
  the device's tailnet address in `REMOTE_ADDR`, not 127.0.0.1. Laravel needs no
  `trustProxies` for that, or for https links: PHP-FPM gets both from Caddy
  directly. (With [Herd](#with-laravel-herd-macos), or a dev server on a port, it does.)
- Ports 80 and 443 on the machine itself stay free for nginx, Apache, Herd, Valet
  or anything else. (macOS wouldn't let Caddy have the tailnet's 443 anyway: it
  keeps ports below 1024 on one address for root.)
- With 443 and 80 vhosty's in Serve's config, other tools that publish through
  Serve find them taken instead of quietly taking them over. T3 Code's pairing,
  for one, uses 443 by default; with vhosty there, it stops and asks for another
  port (`--tailscale-serve-port 8443`).

Setup turns this on, so Serve has to be enabled on your tailnet: if it isn't,
setup prints Tailscale's link to enable it. Anything you had on Serve's ports 443
or 80 is replaced, after asking. If something takes them later, `vhosty doctor`
says what and how to move it, and `vhosty rebuild` takes them back. To move
Caddy's own ports, set `VHOSTY_SERVE_PORT` and `VHOSTY_SERVE_HTTP_PORT` in
`~/.vhosty/config`, then run `vhosty rebuild`.

Older vhosty on Linux had Caddy listen on the Tailscale address's 443 itself.
`vhosty rebuild` (which `vhosty update self` runs) moves it behind Serve.

## macOS

PHP comes from Homebrew, through [shivammathur/php](https://github.com/shivammathur/homebrew-php),
which has every version side by side, as Ondřej Surý's repo does for apt.
`vhosty php install 8.4` runs `brew install shivammathur/php/php@8.4`, plus
`redis` and `igbinary` from [shivammathur/extensions](https://github.com/shivammathur/homebrew-extensions)
(the rest of what apt's packages have, like `pdo_pgsql`, `intl` and `gd`, is built in).
vhosty still runs the PHP-FPMs itself, with its own pools and settings; it doesn't
use `brew services`. Each version's CLI is linked as `~/.vhosty/bin/php-8.4`.
Homebrew's newest stable PHP is the plain `php` formula (`php@8.5` is another name
for it), so when the next version comes out, `brew upgrade` moves it on: run
`vhosty php install 8.5` then to keep 8.5.

Older vhosty downloaded static PHP-FPM builds, which can't add extensions. They
keep working until moved: `vhosty setup`, or `vhosty php install <version>` per
version, installs it from Homebrew and removes the old build. `vhosty doctor`
lists any that are left.

Caddy listens behind Tailscale Serve, as on Linux (see
[Tailscale Serve](#tailscale-serve)), so ports 80 and 443 on the Mac itself stay
free for Herd, Valet or anything else.

## Laravel Octane

A site can run on [Laravel Octane](https://laravel.com/docs/octane) instead of
PHP-FPM, at the same address:

```bash
cd ~/Sites/myapp
composer require laravel/octane
php artisan octane:install      # picks the server: FrankenPHP, RoadRunner or Swoole
vhosty octane on
```

vhosty runs `artisan octane:start` as a service, `octane-myapp`, that starts at
boot and restarts if it crashes, and Caddy passes `myapp.yourdomain.dev` to its
port on localhost. If the server isn't downloaded yet, `octane on` does that first.

```bash
vhosty octane                   # sites on Octane
vhosty octane on --workers 4    # 2 workers by default, for each site
vhosty octane reload            # reload the workers by hand
vhosty octane off               # back to PHP-FPM
vhosty restart octane-myapp
vhosty logs octane-myapp
```

- **Code changes reload by themselves** (`--watch`). FrankenPHP watches files on its
  own; RoadRunner and Swoole need Node and `npm i -D chokidar` (run `vhosty rebuild`
  after adding it). Without them, `doctor` says so, and `vhosty octane reload` does it.
- **The app sees its real host and https links** with no changes: Caddy keeps the
  `Host` header, and the service sets `OCTANE_HTTPS=true` (unless the app's `.env`
  says `OCTANE_HTTPS=false`, or its config is cached). For `$request->ip()` to be
  the device and not 127.0.0.1, trust the proxy, as for `artisan serve`:
  `$middleware->trustProxies(at: ['127.0.0.1', '::1']);` in `bootstrap/app.php`.
- **`vhosty ini` applies to the workers** on every server, global and per site.
- **FrankenPHP has its own PHP inside.** `vhosty isolate` and `ext` set what the CLI
  uses, not what serves its requests. RoadRunner and Swoole run on the site's PHP
  version. For Swoole: `vhosty ext install swoole`, which loads it into that PHP
  version's PHP-FPM too (it does nothing there).
- **RoadRunner is told not to serve `.php` files as static files,** which would
  send their source code. If the project has its own `.rr.yaml`, that one's used
  instead: add `http.static.forbid: [".php"]` to it (`doctor` warns if it's missing).
- **Only localhost can reach the port.** For FrankenPHP that takes a copy of Octane's
  Caddyfile in `~/.vhosty/octane/<site>`, written on `rebuild`, so run `vhosty rebuild`
  after updating Octane. `doctor` checks the port isn't open on the tailnet address.
- A `vhosty rebuild` restarts the Octane services, so a new pin or setting applies.

## With Laravel Herd (macOS)

If you use [Laravel Herd](https://herd.laravel.com), vhosty can leave it in charge.
Herd keeps serving your sites (its PHP versions, extensions, parked folders and
links, `herd secure`), and vhosty makes each one reachable on your tailnet:

```
escrow.test (Herd, on the Mac)  →  https://escrow.yourdomain.dev (any tailnet device)
```

```bash
vhosty setup --herd
```

Setup offers this on its own when it finds Herd. Caddy forwards
`<name>.yourdomain.dev` to Herd as `<name>.test` (Herd's TLD, read from its config).
A site you add in Herd works right away; `vhosty sites` lists them.

Herd keeps its ports 80 and 443; Caddy listens behind
[Tailscale Serve](#tailscale-serve), as everywhere.

Herd's nginx stands between Caddy and PHP, so out of the box Laravel sees
`escrow.test` as the host (for links and redirects) and 127.0.0.1 as the client
(`$request->ip()`). Trust the proxy, and it reads what Caddy sends instead:
`X-Forwarded-Host`, `X-Forwarded-Proto`, and `X-Forwarded-For` with the device's
tailnet address. In `bootstrap/app.php`:

```php
->withMiddleware(function (Middleware $middleware) {
    $middleware->trustProxies(at: ['127.0.0.1', '::1']);
})
```

Port sites (`https://5173.yourdomain.dev`) and `vhosty services` work as usual.
The PHP commands (`php`, `isolate`, `ini`, `ext`) and `park`/`link` point you to
Herd's own. `vhosty doctor` checks that Herd is answering and that Serve forwards
to Caddy; `vhosty uninstall` removes the Serve forwards too.

## Updating

```bash
vhosty update self        # vhosty itself: the latest release, then vhosty rebuild
vhosty update             # vhosty, Caddy, and the PHP versions in use (apt or Homebrew)
```

`update self` replaces `~/.vhosty/bin/vhosty` (and the zsh completion), then
runs `vhosty rebuild` with the new version so its changes take effect. Your
settings, sites and services stay as they are. `--ref main` installs changes that
aren't released yet, and `--ref v0.3.0` a particular release. It won't install an
older version over a newer one without `--force`. Installed from a clone? Update
with `git pull && ./install.sh` instead, then `vhosty rebuild`.

`vhosty doctor` tells you when there's a new release. It asks GitHub once per run;
set `VHOSTY_UPDATE_CHECK=0` to turn that off.

## Usage

| Command | What it does |
|---|---|
| `vhosty park [dir]` / `unpark [dir]` | Serve, or stop serving, every folder inside `dir`. Park as many as you like |
| `vhosty link [dir] [--name N]` / `unlink [name]` | Serve one folder, from anywhere, as `N.yourdomain.dev` |
| `vhosty sites` / `links` | List every site and its URL, and flag folders that won't work |
| `vhosty site [name]` | Everything about one site: folder, PHP version, settings |
| `vhosty worktree [add\|link\|remove\|list]` | A git worktree as a site of its own, with its own URL, `.env` and database. See [Git worktrees](#git-worktrees) |
| `vhosty open [site\|port]` / `url` | Open a site, or print its URL. With no argument, the current folder's site |
| `vhosty php [list\|install\|default\|which]` | PHP versions |
| `vhosty isolate <version>` / `unisolate` / `isolated` | Pin a site to a PHP version |
| `vhosty ini [set\|unset\|edit]` | PHP settings, for every site or one |
| `vhosty ext [require\|install\|check]` | PHP extensions each site needs |
| `vhosty services [up\|down\|logs\|...]` | Docker services: databases, caches, search, S3 |
| `vhosty start\|stop\|restart [caddy\|php\|php-8.x]` | Control Caddy and PHP-FPM. `restart` validates the config first |
| `vhosty status` | Service state, process IDs, and sockets |
| `vhosty logs` / `vhosty tail` | Recent logs, or follow them live. `vhosty logs rotate` compresses big ones |
| `vhosty doctor [--fix]` | Check Tailscale, DNS, the certificate, config, sites, extensions, services, and a live HTTPS request. `--fix` repairs what it can, asking first |
| `vhosty prune` | Remove configs for sites whose folder is gone or no longer parked, and generated files nothing uses |
| `vhosty dns sync` | Re-point `*.domain` at this machine, for when its Tailscale IP changes |
| `vhosty update [self\|caddy\|php [version]]` | Update vhosty to the latest release, re-download Caddy, and upgrade PHP (apt on Linux, Homebrew on macOS). See [Updating](#updating) |
| `vhosty edit [config\|php\|env]` | Edit the settings, PHP settings, or the token, then apply them |
| `vhosty rebuild` | Regenerate the config and reload the services |

### What gets served

For a folder `~/Sites/escrow`:

- If it has `public/index.php`, vhosty serves it with PHP (Laravel, Symfony, etc.).
- If it has `index.html`, vhosty serves it as a static site.
- Folder names become hostnames, so stick to letters, numbers, and dashes.
  Hostnames are lowercase: `MyApp` is served at `myapp.yourdomain.dev`. A new
  folder with capitals needs a `vhosty rebuild` first; `vhosty sites` says when.

Folders outside a parked directory can be linked one at a time:
`vhosty link ~/Projects/My\ App` serves it at `https://my-app.yourdomain.dev`
(pick another name with `--name`). A link wins over a parked folder with the same name.

Any dev server works through its port: `https://3000.yourdomain.dev` (Next.js,
Rails), `https://5173.yourdomain.dev` (Vite), `https://8000.yourdomain.dev`
(`artisan serve`). Only the ports in `VHOSTY_PORTS` are forwarded (by default
`3000-5999 6006 8000-8099 8888`), so other things listening on the machine's
localhost, like an admin console or a search engine, stay private to it. To open
another, add it in `~/.vhosty/config` (`VHOSTY_PORTS="3000-5999 6006 8000-8099 8888 9001"`)
and run `vhosty rebuild`.

When something isn't there, vhosty says what and why instead of showing a blank
page: a name with no site lists the paths it checked and links to your sites; a
port with nothing listening, or a PHP version that's down, shows what to run and
reloads every 2 seconds until it comes up. Errors from your app itself (Laravel's
500s, missing assets) pass through untouched.

**Vite:** add [@vhosty/vite-plugin](https://github.com/vhostyhq/vite-plugin)
(`npm i -D @vhosty/vite-plugin`) for HTTPS and hot reload at `https://<port>.<domain>`,
with no config. Laravel setup and mixed-content fixes are in
[docs/laravel-vite.md](docs/laravel-vite.md).

### Git worktrees

When coding agents work on branches side by side, each branch can have its own
site: its own URL, `.env` and database, so it can migrate without touching the
parent's data. Nothing happens by itself: a worktree is a site once you say so.

```bash
cd ~/Sites/ledger
vhosty worktree add feature/x          # https://feature-x--ledger.yourdomain.dev
vhosty worktree add feature/x --copy-db   # the same, with a clone of ledger's data
vhosty worktree link ~/.t3/worktrees/ledger/t3-1234   # a worktree something else made
vhosty worktree                        # list them
vhosty worktree remove feature-x--ledger
```

`add` takes an existing local or remote branch, or makes a new one from the HEAD
you're on. Git refuses a branch that's checked out elsewhere, and vhosty says so.
The folder goes in `~/.vhosty/worktrees/<site>/<branch>`, not a parked folder, where
it would also be served by its folder name; `--path` picks another. `link` is for
worktrees that already exist, such as those from T3 Code: run it inside one, or
point it at one, and it finds the parent through git. The parent has to be a site.

**The name** is `<branch>--<site>`, one DNS label, as the wildcard certificate covers
only one level. It's lowercase letters, numbers and dashes, at most 63 characters; a
longer one is cut, with a short hash of the original. A detached worktree uses its
folder's name. A name that's taken is refused, so `feature/x` and `feature-x` can't
both have a site. The name stays if the worktree changes branch later.

**`.env`** is a copy of the parent's, with the same file permissions, or
`.env.example` if the parent has none. `APP_URL` and `DB_DATABASE` are set in the
copy; the parent's `.env` is only ever read. `REDIS_PREFIX` and `CACHE_PREFIX` are set
too, to the worktree's name, so it can't overwrite the parent's keys or take its queue
jobs. A prefix can't stop `php artisan cache:clear`, which flushes the whole Redis
database: with `CACHE_STORE=redis`, vhosty warns that it also empties the parent's cache
unless you give the worktree its own `REDIS_CACHE_DB`. If the parent sets `SESSION_DOMAIN`, the copy's becomes `null`, so its
cookies aren't shared across the parent's sites. vhosty warns, by key name and never by
value, about settings that still name the parent's address, and once about the riskier
things a copy still shares: `APP_ENV=production`, `FILESYSTEM_DISK=s3` or `AWS_BUCKET`,
payment and API credentials such as `STRIPE_*` and `PLAID_*`, and other databases
(`DB_*_DATABASE`). `HORIZON_PREFIX` isn't set: if the worktree runs Horizon, set it
yourself. With `link`, a `.env` already in the worktree is kept and edited (a prefix of
its own stays), but a symlink there is replaced, never written through.

**The database** is new and empty, so vhosty prints `php artisan migrate --seed`.
A new Postgres database gets the parent's extensions, each in its own schema, since an
app's role usually can't create them. `--copy-db` clones the parent's without holding
it up, in a single-transaction dump that only reads it, with no global lock. On MySQL
and MariaDB the copy leaves out triggers, routines and events, as any of them could
write to another database, and vhosty names what it left out. On Postgres, a parent with
`dblink`, `postgres_fdw` or `file_fdw`, or any foreign table, isn't copied: the database
stays empty, vhosty says why, and exits non-zero.

| The parent's `.env` says | What the worktree gets |
|---|---|
| `mysql`, `mariadb` or `pgsql`, with `DB_HOST=127.0.0.1` (or none) and a port that a running [Docker service](#docker-services) publishes on 127.0.0.1 right now | A new database, `wt_feature_x__ledger`. A database user other than root gets access to it |
| `sqlite` | Its own file, `database/database.sqlite` in the worktree |
| Anything else: another host, `localhost`, `::1`, an empty `DB_HOST`, `DB_SOCKET`, `DB_READ_HOST`, `DB_WRITE_HOST`, `DB_URL`, or a sqlite file that resolves to the parent's | **It stops,** naming the host and database (never a password), as migrating there would change the parent's data |

`--share-db` is how to say that sharing is what you want: the worktree keeps the
parent's database, the site's config records that, and `vhosty worktree list`, `vhosty
site` and `vhosty doctor` show it. `--copy-db` can't copy a database like that, and
can't be combined with `--share-db`. Without one or the other, `composer install` isn't
reached either.

`DB_HOST=localhost` stops it too, with a message to use `127.0.0.1`: `pdo_mysql` takes
`localhost` for the unix socket, and libpq tries whatever the resolver lists first, which
on a Mac can be `::1`.

`add` looks twice: before git changes anything, and again once the checkout is there, at
the `.env` the worktree really ends up with, as a branch can bring its own `.env` or
`.env.example` and a `post-checkout` hook can write one. If that one isn't managed,
vhosty undoes the worktree it made, with `git worktree remove` and never `--force`, and
says if the branch was new and stays.

If the service is down, or the database name is taken, `add` stops rather than guess.
With `link`, a `.env` keeps its database only if that's vhosty's own name for the site,
or it differs from everything in the parent's `.env`, compared case-insensitively. One
that names the parent's database gets a new one of its own instead, and if the parent's
can't be worked out (no `.env`, or a `${VAR}` that the file doesn't fill in), `link`
stops unless you pass `--share-db`. vhosty's own name is created if it's missing, so
`link` run again repairs a failed create; another name that's missing gets a warning.
`link --copy-db` on a site that already has its database is an error: remove it and add
it again.

**PHP:** a worktree site gets the parent's PHP pin, settings and extensions, copied
when it's made. It runs on PHP-FPM, even if the parent is on Octane, until
`vhosty octane on <name>`. `composer install` runs through the `php` shim, so with the
site's version; if it fails the site stays and vhosty says so. `--no-install` skips
it. npm is never run; it's printed as a next step if there's a lockfile.

**`remove`** does only what vhosty set up, and the site's config records what that is:

- A worktree from `add` is removed with `git worktree remove`, never `--force`, so
  uncommitted or untracked files, submodules or a lock stop it, and vhosty says which
  and what to run by hand. The branch always stays. git can also fail partway, once it
  has started deleting. vhosty compares the folder before and after, and if it changed,
  says files may be gone and names what's left.
- Ignored files go with the folder, as git doesn't count them. vhosty lists them (leaving
  out `vendor`, `node_modules` and the like) and asks. `--yes` goes ahead, and still lists
  them. It warns the same way about commits on a detached HEAD that no branch or tag
  contains.
- A worktree from `link` isn't vhosty's: the folder stays, and only the site and
  vhosty's database go.
- The database vhosty created is dropped after a confirmation that names it. `--yes`
  skips that, for scripts; without a terminal, it's required. `--keep-db` keeps the
  database and prints how to drop it. For sqlite, it first copies the file the app really
  uses (with no database settings, Laravel's `database/database.sqlite`) to a name of its
  own in `~/.vhosty/worktrees`, before touching the folder. vhosty never deletes that
  copy, even if the removal then fails. Only a database under vhosty's own name for this
  site is dropped, whatever the record says, and one that fails to drop is reported, with
  the site kept so you can run it again.
- Nothing is dropped if its whole name appears anywhere in a `.env*` file of the parent or
  any other site or worktree, comments included, in any case, and after decoding `%XX`.
  A longer name is another database, so a sibling's `wt_x__ledger2` doesn't stop the drop
  of `wt_x__ledger`. vhosty says which file named it. If one of those files or
  folders can't be read, or the parent's database keys use a `${VAR}` that doesn't
  resolve, vhosty can't tell, so it refuses, and prints how to drop it by hand. A sibling
  folder that isn't there gets a note and is skipped. A sqlite file that has become a
  link, or is reached through one, or is the parent's file, is refused too, and so is a
  folder that now resolves somewhere other than where the site was made. These are all
  checked again after the confirmation.

If the folder is deleted some other way (`git worktree remove` by hand, or by T3),
`vhosty doctor` says so and `vhosty worktree remove` still works. `vhosty prune` leaves
that site's config alone while it records a database, and says how to drop it: the
record is what lets vhosty drop it safely.

Unlinking or unparking the parent leaves its worktree sites working, as they have
their own folder, URL, `.env` and database; vhosty says which ones. `vhosty unlink`
refuses a worktree site: use `vhosty worktree remove`.

Worktree databases are throwaway, so `vhosty services backup` skips exactly the ones
current worktree sites record, and says which. With [Herd](#with-laravel-herd-macos) serving the sites, these
commands are off.

### PHP versions

```bash
vhosty php install 8.4      # apt (Linux) or Homebrew (macOS), with the usual Laravel extensions
vhosty php default 8.5      # what every site uses unless pinned
cd ~/Sites/legacy && vhosty isolate 8.4
vhosty isolated             # list pins
vhosty unisolate legacy
```

Pins are stored in `~/.vhosty`, not in your projects. A PHP-FPM runs for each
version in use and stops when nothing uses it.

With `~/.vhosty/bin` first on your `PATH`, the `php` command (and so
`php artisan` and `composer`) runs the pinned version, with the same settings as
the site, anywhere inside its folder. `VHOSTY_PHP_VERSION=8.5 php ...` overrides
it for one command. Each version's own CLI is there too: `php8.4` on Linux,
`php-8.4` on macOS.

### PHP settings

```bash
vhosty ini                                  # global settings, plus the current site's
vhosty ini set memory_limit -1 --global     # every site, web and CLI
cd ~/Sites/myspace && vhosty ini set max_execution_time 300   # just this site
vhosty ini set upload_max_filesize 1G --site escrow
vhosty ini unset max_execution_time
vhosty ini edit [--global | --site NAME]
```

Inside a site's folder, `ini` commands change that site; elsewhere, the global
settings (`~/.vhosty/php.ini`). Site settings replace global ones key by key and
apply on the web and in the CLI. A site with its own settings gets its own
PHP-FPM pool, so settings never leak between sites. Settings PHP only reads at
startup (`extension`, `opcache.memory_consumption`) belong in PHP's own php.ini:
`/etc/php/<version>/fpm/` and `/cli/` on Linux, `$(brew --prefix)/etc/php/<version>/`
on macOS.

### PHP extensions

vhosty checks each site against its own PHP version, so a missing extension
shows up in `vhosty doctor` instead of as a 500:

- **Required** extensions come from the project's `composer.lock` (anything a
  package requires, like `ext-soap`). Nothing to configure.
- **Declared** extensions are ones a site needs but its packages only suggest,
  like `protobuf` for the Google Ads API's speed. Declare them without touching
  the project; they're stored in `~/.vhosty/sites/<name>.conf`.

```bash
cd ~/Sites/myspace && vhosty ext require protobuf # declare (and install if missing)
vhosty ext                                        # this site: declared and required
vhosty ext check                                  # every site
vhosty ext install mongodb --php 8.4              # installs it, restarts that FPM
```

`ext install` uses apt on Linux (`php8.4-mongodb`). On macOS it uses
shivammathur/extensions (`mongodb@8.4`) when it has the extension, and that
version's `pecl` otherwise.

`vhosty isolate` warns when the new version lacks something the site needs,
and `vhosty php install` installs every declared extension along with the
version. If a site can't work at all without an extension, declare it in the
project's `composer.json` (`"ext-name": "*"`) instead, so it travels with the code.

### Docker services

Databases, caches, search and S3 run in Docker, managed with `docker compose`.
Start with the standard set, or point vhosty at a `compose.yaml` you already have:

```bash
vhosty services init         # MySQL 8.4, Postgres 18 + pgvector, Valkey, Meilisearch, Typesense, RustFS
vhosty services init --only mysql,valkey
vhosty services dir ~/Sites/services   # or use your own compose.yaml
```

`init` writes `compose.yaml` to `~/.vhosty/services` (or the folder you give it),
with every port on 127.0.0.1, MySQL and Postgres sized for the machine's memory,
and a `.env` of generated keys. Then:

```bash
vhosty services              # state, health and ports of each service
vhosty services up           # start everything (or name services)
vhosty services logs mysql
vhosty services exec mysql mysql -uroot
vhosty services pull         # update images and recreate
```

Docker bypasses the firewall for published ports, so publish them on localhost
(`"127.0.0.1:3306:3306"`). `vhosty services` and `vhosty doctor` flag any port
that isn't.

#### Backups

```bash
vhosty services backup                  # into ~/.vhosty/backups/services-<date>
vhosty services backup --to /mnt/usb
vhosty services restore ~/.vhosty/backups/services-20261030-112158
```

A backup is one folder holding:

- `config/`: `compose.yaml`, `.env` and the other files next to them,
- a SQL dump of every MySQL/MariaDB and Postgres database (plus Postgres roles),
  which loads into newer versions too,
- a `.tar.gz` of every volume of the other services (Valkey, search indexes, S3
  files). Each of those services stops for the few seconds its archive takes.

Test databases (`test`, `*_test`, `*_testing`, `*_test_<n>`) are skipped, as test
suites recreate them, and so are the databases current [worktree](#git-worktrees) sites
record, which are throwaway. Anything else is backed up, whatever it's called: a database
called `wt_payroll`, or one kept with `--keep-db`. A backup that has a worktree's database
restores it like any other.
Bind-mounted folders aren't included. Backups are readable
by you only, and hold your keys, so copy them somewhere safe. The newest
`VHOSTY_BACKUP_KEEP` (default 7) are kept; set `VHOSTY_BACKUP_DIR` to save
elsewhere by default. `vhosty doctor` warns when the last backup is over a week old.

`restore` is how a new machine gets everything back: it copies the config (keeping
any `compose.yaml` or `.env` already there, unless `--replace-config`), creates the
services, puts the volumes back, starts everything, and loads the dumps. It
replaces the data in those services, so it asks first (`--yes` skips the question).

For nightly backups, run it from cron or a systemd timer:
`vhosty services backup --to <folder your backup tool picks up>`.

## Files

```
~/.vhosty/
├── config                 domain, parked folders, default PHP, services folder
├── php.ini                PHP settings for every site (web and CLI)
├── sites/<name>.conf      one per site with a link, pin, settings, or extensions
├── worktrees/<site>/      git worktrees from `vhosty worktree add`
├── .env                   DNS provider credentials (mode 600)
├── Caddyfile              generated
├── error.html             generated: the page for "no site", and PHP or a dev server down
├── php/<version>/         generated PHP-FPM config, one per version
├── bin/                   vhosty, caddy, php (the CLI shim)
├── completions/           zsh completion
├── run/                   sockets
├── logs/                  caddy.log, php-<version>.log, rotated copies (*.log.1.gz …)
├── services/              compose.yaml and .env from `vhosty services init`
└── backups/               `vhosty services backup` (services-<date>/)
```

Services: `~/.config/systemd/user/vhosty-caddy.service`, `vhosty-php@.service` and
`vhosty-logs.timer` on Linux; `/Library/LaunchDaemons/link.vhosty.*.plist` on macOS
(`caddy`, `php-<version>`, and `logs`).

Edit `config` or `php.ini` by hand if you like, then run `vhosty rebuild`.

Logs are rotated once they pass `VHOSTY_LOG_MAX_MB` (default 10): the current
file is compressed to `<name>.log.1.gz` and the newest `VHOSTY_LOG_KEEP` (default
5) copies are kept. This runs daily: a systemd timer (`vhosty-logs.timer`) on
Linux, a launchd daemon (`link.vhosty.logs`) on macOS. `vhosty logs rotate
--force` rotates now. The services keep running throughout.

## After a reboot

The services start on their own, before anyone logs in. Check with `vhosty status`.

On **macOS**, two settings decide whether you can reach them:

- **Tailscale has to connect without anyone logging in.** The App Store version only connects after login. Either turn on automatic login, or use the standalone Tailscale installer with "run unattended" enabled.
- **Sleep:** in System Settings → Energy, turn on "Prevent automatic sleeping when the display is off."

On **Linux**, turn off automatic suspend (GNOME: Settings → Power).

## Troubleshooting

Start with `vhosty doctor`. It checks everything below, and `vhosty doctor --fix`
repairs what it can: DNS, configs for deleted sites, missing extensions, a stale
config, stopped services and Docker services. It asks before each fix (`--yes`
skips the questions).

Deleting a project doesn't delete its vhosty settings (PHP pin, settings,
extensions), in case the folder comes back. `vhosty prune` lists and removes them.

| Symptom | Fix |
|---|---|
| 525 errors, or CORS errors on every asset | The DNS record is proxied (orange cloud). Run `vhosty dns sync`; it sets the record to DNS only. |
| Site can't be reached | The device you're browsing from isn't on Tailscale, or the machine is asleep. |
| Works on one network but not another | Some routers and DNS filters (Pi-hole, NextDNS) block public names that resolve to private IPs. Allowlist your domain there. |
| "No site called …" (404) | The folder doesn't exist in a parked directory, or it has no `public/index.php` or `index.html`. Run `vhosty sites`. |
| 502 on a folder site | PHP-FPM is down. Run `vhosty logs php`, then `vhosty restart php`. |
| 502 on a port site | Nothing is listening on that port, or it only listens on another interface. |
| A change didn't take effect | `vhosty doctor` says whether the config needs a rebuild. Run `vhosty rebuild`. |
| Sites stopped working after pairing an app over Tailscale (T3 Code, say) | It published itself on Tailscale Serve's port 443, vhosty's. `vhosty doctor` says what it is and how to move it to another port (`tailscale serve --bg --https=8443 …`); then `vhosty rebuild`. |
| Site can't be reached from other devices | Tailscale Serve isn't forwarding to Caddy. `vhosty doctor` checks it; `vhosty rebuild` sets it up again. |

## Security

- Only devices on your tailnet can connect. Anyone who joins your tailnet, or that you share the machine with, can reach every site. Use Tailscale's access controls to restrict that (below).
- Laravel's debug pages (`APP_DEBUG=true`) show environment details, such as database passwords and API keys, to anyone who can load them. That's fine when only you can reach the machine; if others can, limit access (below) or turn debug off.

To let only yourself reach the box's sites, tag the machine and grant HTTPS to it
in your [tailnet policy](https://tailscale.com/kb/1324/grants). Tag it with
`sudo tailscale up --advertise-tags=tag:devbox` (or in the admin console), then:

```jsonc
{
  "tagOwners": { "tag:devbox": ["autogroup:admin"] },
  "grants": [
    // you, from any of your devices, to the box's sites
    { "src": ["you@example.com"], "dst": ["tag:devbox"], "ip": ["tcp:443"] }
    // ...your other grants. Tailscale's default policy allows everything to
    // everyone; a box is only private once that default is narrowed.
  ]
}
```
- Domain names appear in public certificate logs. The wildcard certificate only reveals `*.yourdomain.dev`, not your folder names.

## Development

vhosty is one bash file, `bin/vhosty`, kept compatible with the bash 3.2 that
ships with macOS. [CONTRIBUTING.md](CONTRIBUTING.md) says what's in scope and how
the code is kept. The tests use [bats](https://github.com/bats-core/bats-core):

```bash
bats tests/                      # needs bats-core 1.x
shellcheck --severity=warning bin/vhosty install.sh scripts/*.sh
```

They run in a scratch home with a fake `tailscale`, so they don't touch your
setup. `tests/caddy.bats` runs the generated Caddyfile in a real Caddy with the
DNS plugins (`VHOSTY_TEST_CADDY`, or the one vhosty installed); without one
it's skipped. `tests/worktree-db.bats` runs worktree databases on real MySQL and
Postgres servers, in scratch containers of its own; without docker or the images
it's skipped, as it never pulls one. CI runs everything on Ubuntu and on macOS's bash 3.2.

## Uninstall

```bash
vhosty uninstall          # removes the services
rm -rf ~/.vhosty          # removes everything else
rm ~/.local/bin/vhosty    # or: sudo rm /usr/local/bin/vhosty
```

Then delete the `*.domain` record at your DNS provider.

## License

MIT
