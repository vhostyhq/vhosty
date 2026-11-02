# vhosty in front of Herd: design sketch

Status: implemented (`VHOSTY_BACKEND=herd`, `vhosty setup --herd`), tested against stand-ins for
Herd's nginx (`tests/herd.bats`), and tried on a Mac with Herd. Three changes from the sketch below:

- **Listening:** Caddy can't listen on the Tailscale address's port 443. Since Mojave, macOS lets
  an ordinary user listen below 1024 only on every address at once; one particular address
  (`100.x.y.z:443`) still needs root, and Caddy runs as the user (`bind: permission denied` on
  the first real try). So Caddy listens on `127.0.0.1:48443` (`https_port`, redirects off), and
  Tailscale Serve forwards the tailnet's port 443 to it as plain TCP
  (`tailscale serve --bg --tcp=443 tcp://127.0.0.1:48443`): TLS still ends at Caddy, with the
  wildcard certificate. Setup and `rebuild` set it up, `doctor` checks it, `uninstall` removes
  it. Costs: Serve has to be enabled on the tailnet, no `http://` on the tailnet, and Caddy
  sees every client as 127.0.0.1 (both since fixed: port 80 is forwarded, and Serve sends a
  PROXY header that Caddy reads). Root Caddy and a pf redirect were the alternatives.
  Later the same applied to vhosty's own macOS mode, so the Serve code is now shared by both
  backends, and Serve also forwards the tailnet's port 80 to a redirect on `127.0.0.1:48080`
  ([macos-brew-design.md](macos-brew-design.md)).

- **Secured sites:** Caddy connects to Herd on 443 with `tls_insecure_skip_verify` rather than
  trusting Herd's CA file, whose name and place aren't documented. The hop stays on this machine.
- **The hostname:** current Valet only copies `X-Original-Host` into `X-Forwarded-Host`; it no
  longer replaces `HTTP_HOST`. So vhosty sends no `X-Original-Host`, and the app trusts the proxy
  (127.0.0.1) to use Caddy's `X-Forwarded-Host` and `-Proto`. The README says how.

## Goal

On a Mac that already runs [Laravel Herd](https://herd.laravel.com), give every Herd site a
tailnet URL with a real certificate, with no per-site steps:

```
escrow.test (Herd, on the Mac)  →  https://escrow.yourdomain.dev (any tailnet device)
```

Herd keeps doing what it does: PHP versions, extensions, isolation, its UI, `herd` commands.
vhosty adds only what Herd doesn't have: the tailnet listener, the wildcard certificate, the DNS
record, port forwarding for dev servers, and `doctor`.

## Why not just run vhosty

Today vhosty and Herd can't run together: both want ports 80 and 443, and setup tells you to stop
Herd. On macOS vhosty's own PHP is also its weakest part (static builds with a fixed set of
extensions, no CLI per version). Herd users already have a better PHP; they only lack the
tailnet side.

## Shape

One new setting, `VHOSTY_BACKEND=herd` (default `vhosty`, today's behavior). With `herd`:

- **No PHP-FPM.** `php_enabled` is false: no FPM services, no `php`, `isolate`, `ini` or `ext`
  commands (they say "Herd manages PHP: use `herd ...`"), no shim. `svc_all` is just `caddy`.
- **No parked folders or links of vhosty's own.** Herd's list of sites is the list of sites.
  `park`, `link` and friends say to use `herd park` / `herd link`.
- **Caddy listens on the Tailscale IP only**, not localhost, so it doesn't collide with Herd's
  nginx on 127.0.0.1:80/443.
- **Every `<name>.yourdomain.dev` is proxied to Herd as `<name>.test`.** Caddy doesn't need to know
  the sites, so a new Herd site works without a `vhosty rebuild`.
- Port sites (`5173.yourdomain.dev`) work exactly as today.

## The Caddyfile

`write_caddyfile` keeps the global block, the TLS block, and the port rules. The folder-site part
(`caddy_sites` and the parked loop) is replaced by one proxy rule:

```caddyfile
{
	default_bind 100.x.y.z          # Tailscale IP only
	admin "unix/…/caddy-admin.sock|0600"
}

*.yourdomain.dev {
	tls { dns cloudflare {env.CF_API_TOKEN} }

	# @port / @port_closed: unchanged

	# Herd secures a site with its own CA and redirects http to https, so
	# a secured site has to be reached on 443, an unsecured one on 80
	@herd_secured file "~/Library/Application Support/Herd/config/valet/Certificates/{labels.2}.test.crt"
	handle @herd_secured {
		vars vhosty_kind herd
		reverse_proxy 127.0.0.1:443 {
			header_up Host {labels.2}.test
			header_up X-Original-Host {host}
			transport http {
				tls_server_name {labels.2}.test
				tls_trust_pool file "~/Library/Application Support/Herd/config/valet/CA/LaravelValetCASelfSigned.pem"
			}
		}
	}

	handle {
		vars vhosty_kind herd
		reverse_proxy 127.0.0.1:80 {
			header_up Host {labels.2}.test
			header_up X-Original-Host {host}
		}
	}

	handle_errors { … }   # vhosty's page for 502s: "Herd isn't running"
}
```

(`{labels.2}` stands for `{labels.$depth}`, as today. `~` is shorthand here: Caddy doesn't expand
it, so the generated file has the full home path. The TLD comes from Herd's
`config/valet/config.json`, `"tld"`, not hard-coded `test`.)

### The hostname problem

Herd's nginx picks the site from `Host`, so it has to see `escrow.test`. But then PHP sees
`HTTP_HOST=escrow.test`, and Laravel builds links, redirects and asset URLs for `escrow.test`,
which a phone can't open.

Herd already solves this for `herd share` (Expose): Valet's `server.php` replaces `HTTP_HOST` with
`X-Original-Host` when it's present ([laravel/valet#342](https://github.com/laravel/valet/issues/342)).
Sending `X-Original-Host: escrow.yourdomain.dev` should make Laravel see the real hostname with no
app changes. **This is the first thing to verify.** If Herd's `server.php` no longer does it, the
fallback is the same as `artisan serve` behind vhosty today: send `X-Forwarded-Host` and
`X-Forwarded-Proto`, and the app trusts proxies from 127.0.0.1 (`docs/laravel-vite.md`).

`X-Forwarded-Proto: https` is needed either way, so Laravel generates `https://` URLs. Caddy
sends it by default.

## Commands

| Command | With `VHOSTY_BACKEND=herd` |
|---|---|
| `setup` | Detects Herd (`herd` CLI or `/Applications/Herd.app`) and offers the Herd backend instead of warning about port 443. Skips the park folder and PHP-FPM steps. |
| `sites` | Reads Herd's sites (`herd sites`, or `config/valet/config.json` paths plus `config/valet/Sites` links) and prints each with its tailnet URL, and whether it's secured. |
| `open` / `url` | Map the current folder to its Herd site name, then the tailnet URL. |
| `status` / `start` / `stop` | Caddy only. `status` also reports whether Herd's nginx answers on 127.0.0.1. |
| `doctor` | Today's Tailscale, DNS, certificate and HTTPS checks, plus: Herd is running; nginx listens on 127.0.0.1 only (if it's on `*:443`, Caddy can't bind the Tailscale IP); a live request through to one Herd site returns the expected host. |
| `php`, `isolate`, `ini`, `ext`, `park`, `link` | Refuse, pointing at the `herd` equivalent. |
| `update` | Caddy and vhosty; no PHP. |

## Code changes

- `VHOSTY_BACKEND` default and `backend_herd()` helper; `php_enabled` returns false under Herd.
- `herd_dir()` (`~/Library/Application Support/Herd`), `herd_tld()`, `herd_sites()`.
- `write_caddyfile`: bind without localhost; replace the folder-site section with the proxy rules
  under Herd. Error page: a "Herd isn't running" case for 502 from the Herd handler.
- `cmd_setup`: Herd detection; skip park and PHP steps.
- Guards in the PHP, park and link commands.
- `doctor_checks`: Herd section.
- Tests: a bats file that generates the Herd Caddyfile against a fake Herd folder (config.json,
  a Certificates dir) and runs it through `caddy validate`, plus an integration test with a
  stub HTTP server on 127.0.0.1 standing in for nginx that echoes `Host` and `X-Original-Host`.
  CI's macOS runner can do this without a real Herd.
- README: a "With Herd" section; the Requirements line about stopping Herd becomes "or use the
  Herd backend".

Linux is untouched: the backend is macOS-only, and setup refuses it elsewhere.

## Verify first (on a Mac with Herd)

1. Herd's nginx listens on `127.0.0.1:80/443`, not `*`. If it's `*`, Caddy can't bind
   `100.x.y.z:443`, and the backend would need Herd's listen lines changed (fragile, since Herd
   regenerates them).
2. Herd's `server.php` still honors `X-Original-Host`, for secured and unsecured sites.
3. Paths: `config/valet/Certificates/<site>.<tld>.crt`, the CA file name, `config.json`'s `tld`
   and `paths`.
4. Caddy accepts placeholders in `tls_server_name` and in the `file` matcher's path.
5. Vite: the `@vhosty/vite-plugin` setup works the same when the page comes through Herd.
6. Herd Pro services (MySQL, Redis) don't conflict with `vhosty services`; the simplest answer is
   to not offer `services` under Herd.
