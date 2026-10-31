# vhosty on InstaBox

[InstaBox](https://instabox.sh) gives you Linux VMs in the cloud, made for
coding agents. Each one is a real VM (Firecracker, Debian 13, systemd), so it
runs vhosty like any Linux machine: one box per developer, or per project, each
with its own `*.domain`, reachable from every device on your tailnet.

```
alice's box  →  https://<folder>.alice.example.com
bob's box    →  https://<folder>.bob.example.com
```

## One line

From your own computer, with Node.js installed:

```bash
curl -fsSL https://raw.githubusercontent.com/vhostyhq/vhosty/main/scripts/instabox.sh \
  | bash -s -- --name alice --domain alice.example.com --services mysql,valkey
```

It asks for anything it doesn't have, then:

1. creates the machine `alice`: always on, 8 vCPU / 16 GB and a 100 GB disk, where your plan allows,
2. hands it your tokens through the instabox CLI (never on a command line; the box deletes them once read),
3. runs [`box-setup.sh`](../scripts/box-setup.sh) on it, which:
   - installs what vhosty needs that the image lacks (`setcap`),
   - moves Docker's images and volumes to `/data`, the big disk (the root disk is 16 GB),
   - installs Tailscale and joins your tailnet as `alice`,
   - installs vhosty (the latest release) and PHP (8.4 from Debian),
   - runs `vhosty setup`: the `*.alice.example.com` DNS record, Caddy, the wildcard certificate,
   - sets up the Docker services you asked for,
   - puts a `hello` site in `~/Sites`, and runs `vhosty doctor`.

It takes a few minutes. Then open `https://hello.alice.example.com` on your phone.

| Option | |
|---|---|
| `--name N` | Machine name, also its name on your tailnet (required) |
| `--domain D` | Its domain, on Cloudflare. Default: `N.<your vhosty domain>`, when the computer you run it from has vhosty set up |
| `--size C/G` | vCPUs/GB of memory. Default `8/16`, else the biggest your plan has |
| `--disk GB` | Disk for home and Docker. Default `100` |
| `--services LIST` | Docker services, like `mysql,valkey` (see `vhosty services init`) |
| `--php V`, `--no-php` | PHP version (default: the newest Debian has), or none |
| `--ref R` | vhosty version on the box: a tag, or `main`. Default: the latest release |

### What you need

- **The instabox CLI, signed in:** `npx instabox@latest login`. Or set `INSTABOX_API_KEY`.
- **A Cloudflare API token** with Zone → Read and DNS → Edit for the domain, as for
  `vhosty setup`. If the computer you run it from has vhosty set up, its token is used.
  Otherwise set `CF_API_TOKEN`, or paste it when asked.
- **A Tailscale auth key** (login.tailscale.com → Settings → Keys). Set `TS_AUTHKEY`, or
  paste it when asked. For a box you'll throw away, make it *ephemeral*: the node
  leaves your tailnet on its own once the machine is gone.

## Plans

The **free plan** works for trying it, with limits you can't change: one size
(4 vCPU, 8 GB, 20 GB disk), and a machine pauses after 30 idle minutes and after 8
hours of running. A paused machine drops off your tailnet, and traffic over Tailscale
doesn't wake it, so its sites stop answering until you run `instabox wake`.

For a box you can open any time, use **Pro** or above. The one-liner turns idle
pausing off (`--auto-suspend 0`), and paid plans have no running limit. Rough cost of
an always-on box, from InstaBox's unit prices (check the
[pricing page](https://instabox.sh/pricing)):

| Size | A month, always on |
|---|---|
| 4 vCPU / 8 GB | about $25, plus disk over 20 GB |
| 8 vCPU / 16 GB | about $50, plus disk over 20 GB |

100 GB of disk adds about $6 a month; 200 GB about $14.

## Working on a box

- `instabox ssh alice` opens a shell. `instabox ssh-config alice >> ~/.ssh/config`
  lets editors (VS Code, Cursor, Zed) and other tools connect over SSH.
- Everything vhosty does works as on any Linux machine: `vhosty sites`, `vhosty
  isolate`, `vhosty services`, `vhosty update self`. Put projects in `~/Sites`.
- Dev servers work through their port: `https://5173.alice.example.com`.
- After a restart, Caddy, PHP-FPM, Tailscale and the Docker services come back on
  their own.
- `instabox snapshot save alice --name alice-base` saves the whole box. A new box from
  that snapshot (`instabox create --snapshot alice-base`) needs its own Tailscale
  identity and domain, so run `box-setup.sh` on it again.

## Things to know

- Home is on `/data` (`/data/home`). That's the disk that grows with `--disk`; the
  root disk stays 16 GB, which is why Docker's data is moved.
- PHP comes from Debian (8.4). For other versions, add
  [Ondřej Surý's repo](https://packages.sury.org/php/README.txt) for Debian, then
  `vhosty php install 8.5`.
- A machine sends at most about 6 MB/s, so big downloads from it are slow. Browsing
  sites is fine.
- InstaBox is young (it launched in October 2026), so plans and limits may change.

## Removing a box

```bash
instabox rm alice --yes
```

Then delete its DNS record (`*.alice.example.com`) in Cloudflare. An ephemeral
Tailscale node removes itself; otherwise remove `alice` in the Tailscale admin console.

## Other clouds

`box-setup.sh` works on any fresh Debian or Ubuntu VM with sudo: a DigitalOcean
droplet, a Hetzner server, and so on. Run it on the VM, as the user who'll own the
sites:

```bash
curl -fsSL https://raw.githubusercontent.com/vhostyhq/vhosty/main/scripts/box-setup.sh \
  | VHOSTY_DOMAIN=alice.example.com VHOSTY_SERVICES=mysql,valkey bash
```

It asks for the Cloudflare token and the Tailscale auth key. The settings it reads are
listed at the top of the script. On a VM with a public IP, also close every inbound
port in the provider's firewall and use Tailscale SSH: vhosty itself only listens on
the tailnet.
