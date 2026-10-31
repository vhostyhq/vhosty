# vhosty

**Herd for your tailnet.** Every folder becomes a private HTTPS site on your own
domain, reachable from your phone, laptop, or any device on your
[Tailscale](https://tailscale.com) network.

```
~/Sites/escrow   →  https://escrow.yourdomain.dev
~/Sites/kudos    →  https://kudos.yourdomain.dev
localhost:5173   →  https://5173.yourdomain.dev
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
                         └─ Caddy :443   *.yourdomain.dev, wildcard cert
                              ├─ <port>.yourdomain.dev  → localhost:<port>
                              ├─ <site>.yourdomain.dev  → PHP-FPM <version> (site/public/index.php)
                              └─ <site>.yourdomain.dev  → static (site/index.html)
```

1. **DNS:** one wildcard record, `*.yourdomain.dev`, points at the machine's Tailscale IP. The name is public, but the IP is only reachable from your tailnet.
2. **Certificates:** Caddy proves it owns the domain with a DNS challenge through Cloudflare's API, so Let's Encrypt never needs to reach the machine.
3. **Routing:** Caddy reads the hostname and serves the matching folder (PHP through PHP-FPM, or static files) or proxies a port. It listens on the Tailscale IP and localhost only, not your LAN.
4. **Services:** Caddy and one PHP-FPM per PHP version in use. On Linux they're systemd user services (no sudo to manage them); on macOS, launchd daemons. They start at boot and restart if they crash.

## Requirements

- **[Tailscale](https://tailscale.com/download)** on this machine and on every device you'll browse from.
- **A domain with its DNS on [Cloudflare](https://cloudflare.com)**, either one you own or a new one. It doesn't have to be dedicated to vhosty: if its `*` record is already used (say, by staging sites), use a subdomain like `box.example.com`.
- **A Cloudflare API token** with *Zone → Read* and *DNS → Edit* for that domain. Create one at dash.cloudflare.com → My Profile → API Tokens, using the "Edit zone DNS" template.
- **Ports 80 and 443 free.** Herd, Valet, nginx and Apache use them, so stop those first.

**Linux** (tested on Ubuntu 26.04): systemd, `curl`, `jq`, and PHP from apt. Ubuntu
ships one PHP version; for several side by side, add Ondřej Surý's repo
([packages.sury.org/php](https://packages.sury.org/php/README.txt)), then
`vhosty php install 8.4`. Setup asks for your password twice, once each to let
your services run at boot (`loginctl enable-linger`) and to let Caddy use ports
80 and 443 (`setcap`). Nothing else needs root.

**macOS** 13 (Ventura) or newer, Intel or Apple Silicon. No Homebrew needed:
vhosty downloads static PHP-FPM builds. Starting and stopping services asks for
your password (launchd daemons).

vhosty downloads its own Caddy, with the Cloudflare plugin built in.

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

- downloads Caddy into `~/.vhosty/bin` (and PHP-FPM on macOS),
- creates or fixes the `*.domain` DNS record (DNS only, not proxied),
- generates the Caddyfile and PHP-FPM configs,
- installs and starts the services, and
- waits for the wildcard certificate.

To run it without prompts:

```bash
vhosty setup --domain box.example.com --token "$CF_TOKEN" --park ~/Sites --yes
```

Add `~/.vhosty/bin` to the front of your `PATH` so `php` follows the site you're
in (see [PHP versions](#php-versions)), and turn on tab completion (zsh):

```bash
export PATH="$HOME/.vhosty/bin:$PATH"
fpath=(~/.vhosty/completions $fpath)   # before compinit
```

## Updating

```bash
vhosty update self        # vhosty itself: the latest release, then vhosty rebuild
vhosty update             # vhosty, Caddy, and PHP-FPM on macOS
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
| `vhosty prune` | Remove configs for sites whose folder is gone, and generated files nothing uses |
| `vhosty dns sync` | Re-point `*.domain` at this machine, for when its Tailscale IP changes |
| `vhosty update [self\|caddy\|php]` | Update vhosty to the latest release, and re-download Caddy (and PHP-FPM on macOS). See [Updating](#updating) |
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
(`artisan serve`).

When something isn't there, vhosty says what and why instead of showing a blank
page: a name with no site lists the paths it checked and links to your sites; a
port with nothing listening, or a PHP version that's down, shows what to run and
reloads every 2 seconds until it comes up. Errors from your app itself (Laravel's
500s, missing assets) pass through untouched.

**Vite:** add [@vhosty/vite-plugin](https://github.com/vhostyhq/vite-plugin)
(`npm i -D @vhosty/vite-plugin`) for HTTPS and hot reload at `https://<port>.<domain>`,
with no config. Laravel setup and mixed-content fixes are in
[docs/laravel-vite.md](docs/laravel-vite.md).

### PHP versions

```bash
vhosty php install 8.4      # Linux: apt packages with the usual Laravel extensions
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
it for one command. On macOS the shim uses the `php` on your `PATH` for versions
it can't find.

### PHP settings

```bash
vhosty ini                                  # global settings, plus the current site's
vhosty ini set memory_limit -1 --global     # every site, web and CLI
cd ~/Sites/kudos && vhosty ini set max_execution_time 300   # just this site
vhosty ini set upload_max_filesize 1G --site escrow
vhosty ini unset max_execution_time
vhosty ini edit [--global | --site NAME]
```

Inside a site's folder, `ini` commands change that site; elsewhere, the global
settings (`~/.vhosty/php.ini`). Site settings replace global ones key by key and
apply on the web and in the CLI. A site with its own settings gets its own
PHP-FPM pool, so settings never leak between sites. Settings PHP only reads at
startup (`extension`, `opcache.memory_consumption`) belong in the distro's php.ini.

### PHP extensions

vhosty checks each site against its own PHP version, so a missing extension
shows up in `vhosty doctor` instead of as a 500:

- **Required** extensions come from the project's `composer.lock` (anything a
  package requires, like `ext-soap`). Nothing to configure.
- **Declared** extensions are ones a site needs but its packages only suggest,
  like `protobuf` for the Google Ads API's speed. Declare them without touching
  the project; they're stored in `~/.vhosty/sites/<name>.conf`.

```bash
cd ~/Sites/kudos && vhosty ext require protobuf   # declare (and install if missing)
vhosty ext                                        # this site: declared and required
vhosty ext check                                  # every site
vhosty ext install mongodb --php 8.4              # Linux: apt php8.4-mongodb, restarts that FPM
```

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

Test databases (`test`, `*_test`, `*_testing`, `*_test_<n>`) are skipped; test
suites recreate them. Bind-mounted folders aren't included. Backups are readable
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
├── .env                   Cloudflare token (mode 600)
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

Services: `~/.config/systemd/user/vhosty-caddy.service` and `vhosty-php@.service`
on Linux; `/Library/LaunchDaemons/link.vhosty.*.plist` on macOS.

Edit `config` or `php.ini` by hand if you like, then run `vhosty rebuild`.

Logs are rotated once they pass `VHOSTY_LOG_MAX_MB` (default 10): the current
file is compressed to `<name>.log.1.gz` and the newest `VHOSTY_LOG_KEEP` (default
5) copies are kept. On Linux a daily systemd timer (`vhosty-logs.timer`) does it;
on macOS it happens whenever vhosty sets up the services. `vhosty logs rotate
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
| Port 443 in use | Herd, Valet, nginx or Apache is running. Stop it. |

## Security

- Only devices on your tailnet can connect. Anyone who joins your tailnet, or that you share the machine with, can reach every site. Use Tailscale's access controls to restrict that.
- Laravel's debug pages (`APP_DEBUG=true`) show environment details to anyone who can load them.
- Domain names appear in public certificate logs. The wildcard certificate only reveals `*.yourdomain.dev`, not your folder names.

## Uninstall

```bash
vhosty uninstall          # removes the services
rm -rf ~/.vhosty          # removes everything else
rm ~/.local/bin/vhosty    # or: sudo rm /usr/local/bin/vhosty
```

Then delete the `*.domain` record in Cloudflare.

## License

MIT
