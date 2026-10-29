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
- Built for an always-on dev box, like an old iMac running your coding agents, that you check from anywhere.

## How it works

```
your phone ──tailnet──▶ Mac (100.x.y.z)
                         └─ Caddy :443   *.yourdomain.dev, wildcard cert
                              ├─ <port>.yourdomain.dev  → localhost:<port>
                              ├─ <folder>.yourdomain.dev → PHP-FPM (folder/public/index.php)
                              └─ <folder>.yourdomain.dev → static (folder/index.html)
```

1. **DNS:** one wildcard record, `*.yourdomain.dev`, points at the Mac's Tailscale IP. The name is public, but the IP is only reachable from your tailnet.
2. **Certificates:** Caddy proves it owns the domain with a DNS challenge through Cloudflare's API, so Let's Encrypt never needs to reach the machine.
3. **Routing:** Caddy reads the hostname and serves the matching folder (PHP through PHP-FPM, or static files) or proxies a port.
4. **Services:** Caddy and PHP-FPM run as launchd services. They start at boot, before login, and restart if they crash.

## Requirements

- **macOS 13 (Ventura) or newer**, Intel or Apple Silicon. No Homebrew needed.
- **[Tailscale](https://tailscale.com/download)** on this Mac and on every device you'll browse from.
- **A domain with its DNS on [Cloudflare](https://cloudflare.com)**, either one you own or a new one. It doesn't have to be dedicated to vhosty: if its `*` record is already used (say, by staging sites), use a subdomain like `box.example.com`.
- **A Cloudflare API token** with *Zone → Read* and *DNS → Edit* for that domain. Create one at dash.cloudflare.com → My Profile → API Tokens, using the "Edit zone DNS" template.
- **Ports 443 and 9000 free.** Herd and Valet use 443, so stop them first.

vhosty downloads its own Caddy (with the Cloudflare plugin built in) and a
static PHP-FPM build that matches your `php -v`.

## Install

```bash
git clone https://github.com/vhostyhq/vhosty.git
cd vhosty && ./install.sh
vhosty setup
```

Once the repo is public, this one-liner will work too:

```bash
curl -fsSL https://raw.githubusercontent.com/vhostyhq/vhosty/main/install.sh | bash
```

`vhosty setup` asks for your domain, token, and the folder to park, then:

- downloads Caddy and PHP-FPM into `~/.vhosty/bin`,
- creates or fixes the `*.domain` DNS record (DNS only, not proxied),
- generates the Caddyfile and `php-fpm.conf`,
- installs and starts the launchd services, and
- waits for the wildcard certificate.

To run it without prompts:

```bash
vhosty setup --domain box.example.com --token "$CF_TOKEN" --park ~/Sites --yes
```

## Usage

| Command | What it does |
|---|---|
| `vhosty park [dir]` / `unpark [dir]` | Serve, or stop serving, every folder inside `dir` |
| `vhosty sites` | List every site and its URL, and flag folders that won't work |
| `vhosty open [site\|port]` | Open a site. With no argument, it opens the current folder's site |
| `vhosty url [site\|port]` | Print a site's URL and copy it |
| `vhosty start\|stop\|restart [caddy\|php-fpm]` | Control the services. `restart` validates the config first |
| `vhosty status` | Service state, process IDs, and ports |
| `vhosty logs` / `vhosty tail` | Recent logs, or follow them live |
| `vhosty doctor` | Check Tailscale, DNS, the certificate, services, and a live HTTPS request |
| `vhosty dns sync` | Re-point `*.domain` at this Mac, for when its Tailscale IP changes |
| `vhosty update [caddy\|php [8.x]]` | Re-download Caddy or PHP-FPM |
| `vhosty edit [config\|env]` | Edit the settings or the token, then apply them |
| `vhosty rebuild` | Regenerate the Caddyfile and restart |

### What gets served

For a folder `~/Sites/escrow`:

- If it has `public/index.php`, vhosty serves it with PHP (Laravel, Symfony, etc.).
- If it has `index.html`, vhosty serves it as a static site.
- Folder names become hostnames, so stick to letters, numbers, and dashes.

Any dev server works through its port: `https://3000.yourdomain.dev` (Next.js,
Rails), `https://5173.yourdomain.dev` (Vite), `https://8000.yourdomain.dev`
(`artisan serve`).

**Vite:** add [@vhosty/vite-plugin](https://github.com/vhostyhq/vite-plugin)
(`npm i -D @vhosty/vite-plugin`) for HTTPS and hot reload at `https://<port>.<domain>`,
with no config. Laravel setup and mixed-content fixes are in
[docs/laravel-vite.md](docs/laravel-vite.md).

## Files

```
~/.vhosty/
├── config          domain, parked folders, PHP on/off (edit, then `vhosty rebuild`)
├── .env            Cloudflare token (mode 600)
├── Caddyfile       generated
├── php-fpm.conf    generated
├── bin/            vhosty, caddy, php-fpm
└── logs/           caddy.log, php-fpm.log
/Library/LaunchDaemons/link.vhosty.caddy.plist
/Library/LaunchDaemons/link.vhosty.php-fpm.plist
```

## After a reboot

The services start on their own. Two macOS settings decide whether you can reach them:

- **Tailscale has to connect without anyone logging in.** The App Store version only connects after login. Either turn on automatic login, or use the standalone Tailscale installer with "run unattended" enabled.
- **Sleep:** in System Settings → Energy, turn on "Prevent automatic sleeping when the display is off."

## Troubleshooting

Start with `vhosty doctor`. It checks everything below.

| Symptom | Fix |
|---|---|
| 525 errors, or CORS errors on every asset | The DNS record is proxied (orange cloud). Run `vhosty dns sync`; it sets the record to DNS only. |
| Site can't be reached | The device you're browsing from isn't on Tailscale, or the Mac is asleep. |
| Works on one network but not another | Some routers and DNS filters (Pi-hole, NextDNS) block public names that resolve to private IPs. Allowlist your domain there. |
| `vhosty: no site found` (404) | The folder doesn't exist in a parked directory, or it has no `public/index.php` or `index.html`. Run `vhosty sites`. |
| 502 on a folder site | PHP-FPM is down. Run `vhosty logs php-fpm`, then `vhosty restart php-fpm`. |
| 502 on a port site | Nothing is listening on that port, or it only listens on another interface. |
| Port 443 in use | Herd or Valet is running. Stop it. |

## Security

- Only devices on your tailnet can connect. Anyone who joins your tailnet, or that you share the Mac with, can reach every parked site. Use Tailscale's access controls to restrict that.
- Laravel's debug pages (`APP_DEBUG=true`) show environment details to anyone who can load them.
- Domain names appear in public certificate logs. The wildcard certificate only reveals `*.yourdomain.dev`, not your folder names.

## Uninstall

```bash
vhosty uninstall          # removes the launchd services
rm -rf ~/.vhosty          # removes everything else
sudo rm /usr/local/bin/vhosty
```

Then delete the `*.domain` record in Cloudflare.

## License

MIT
