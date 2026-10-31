#!/usr/bin/env bash
#
# Turns a fresh Debian or Ubuntu VM into a vhosty box: Tailscale, vhosty,
# PHP-FPM, Docker on the big disk, and (if you like) Docker services, then
# `vhosty setup`. For cloud VMs: InstaBox, droplets, and the like.
#
# Run it on the VM, as the user who'll own the sites (it uses sudo):
#
#   curl -fsSL https://raw.githubusercontent.com/vhostyhq/vhosty/main/scripts/box-setup.sh \
#     | VHOSTY_DOMAIN=alice.example.com bash
#
# Settings, from the environment:
#   VHOSTY_DOMAIN        the box's domain, on Cloudflare (sites are *.domain); required
#   CF_API_TOKEN         Cloudflare token with Zone Read and DNS Edit; asked for if missing
#   TS_AUTHKEY           Tailscale auth key, when the VM isn't on your tailnet yet; asked for if missing
#   TS_HOSTNAME          the VM's name on the tailnet (default: its hostname)
#   VHOSTY_PARK          folder whose subfolders become sites (default: ~/Sites)
#   VHOSTY_PHP           PHP version, or "off" (default: the newest apt offers)
#   VHOSTY_SERVICES      Docker services to set up, like mysql,valkey (default: none)
#   VHOSTY_DATA_DIR      disk for Docker's images and volumes (default: /data when it's
#                        a disk of its own, as on InstaBox; "none" leaves Docker alone)
#   VHOSTY_REF           vhosty version to install: a tag, or main (default: the latest release)
#   VHOSTY_SECRETS_FILE  a file of CF_API_TOKEN= and TS_AUTHKEY= lines, read and then deleted
#
# Safe to run again: it skips what's already done.

set -euo pipefail

if [ -t 1 ]; then B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; D=$'\033[2m'; N=$'\033[0m'
else B=""; G=""; Y=""; R=""; D=""; N=""; fi
ok()   { printf "  %s✓%s %s\n" "$G" "$N" "$*"; }
warn() { printf "  %s!%s %s\n" "$Y" "$N" "$*"; }
info() { printf "  %s%s%s\n" "$D" "$*" "$N"; }
step() { printf "\n%s→ %s%s\n" "$B" "$*" "$N"; }
die()  { printf "%serror:%s %s\n" "$R" "$N" "$*" >&2; exit 1; }

REPO="${VHOSTY_REPO:-vhostyhq/vhosty}"
VHOSTY_BIN="$HOME/.vhosty/bin"
export PATH="$VHOSTY_BIN:$PATH"

has_tty() { { : </dev/tty; } 2>/dev/null; }

# Runs a chatty command (apt, image pulls), showing only vhosty's own result
# lines; everything it printed if it fails
quiet() {
  local out
  if out="$("$@" 2>&1)"; then
    printf '%s\n' "$out" | grep -E '^ +(✓|!|✗) ' || true
  else
    printf '%s\n' "$out" | tail -25
    die "failed: $*"
  fi
}

# ask_secret VAR "Prompt": fills VAR from the terminal when it's empty
ask_secret() {
  local v=""
  [ -z "${!1:-}" ] || return 0
  has_tty || die "$1 is needed. Set it, or run this from a terminal."
  printf "  %s: " "$2" >/dev/tty
  IFS= read -rs v </dev/tty
  printf '\n' >/dev/tty
  [ -n "$v" ] || die "$1 is needed"
  printf -v "$1" '%s' "$v"
}

# Everything runs from main, called on the last line: piped into bash, the
# whole script is read before any command can swallow the rest of it from stdin
main() {
[ "$(uname -s)" = "Linux" ] || die "box-setup is for Linux VMs. On a Mac, use install.sh and vhosty setup."
command -v apt-get >/dev/null 2>&1 || die "box-setup needs Debian or Ubuntu (apt)"
[ "$(id -u)" != "0" ] || die "Run it as the user who'll own the sites, not root. It uses sudo where it needs to."

printf "%svhosty box setup%s\n" "$B" "$N"

# Secrets handed over in a file (scripts/instabox.sh does this), so they're
# never on a command line
if [ -n "${VHOSTY_SECRETS_FILE:-}" ] && [ -f "$VHOSTY_SECRETS_FILE" ]; then
  while IFS='=' read -r k v; do
    case "$k" in CF_API_TOKEN|TS_AUTHKEY) [ -n "${!k:-}" ] || printf -v "$k" '%s' "$v" ;; esac
  done <"$VHOSTY_SECRETS_FILE"
  rm -f "$VHOSTY_SECRETS_FILE"
fi
CF_API_TOKEN="${CF_API_TOKEN:-}"; TS_AUTHKEY="${TS_AUTHKEY:-}"

domain="${VHOSTY_DOMAIN:-}"
if [ -z "$domain" ]; then
  has_tty || die "Set VHOSTY_DOMAIN, the box's domain (like alice.example.com)"
  printf "  Domain for this box (sites are *.domain): " >/dev/tty
  IFS= read -r domain </dev/tty
  [ -n "$domain" ] || die "A domain is required"
fi
park="${VHOSTY_PARK:-$HOME/Sites}"
php="${VHOSTY_PHP:-}"
services="${VHOSTY_SERVICES:-}"

sudo -n true 2>/dev/null || { info "asks for your password (sudo)"; sudo -v; }

step "Packages"
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl ca-certificates jq git libcap2-bin >/dev/null
ok "curl, jq, git, setcap"

# Docker keeps images and volumes under /var/lib, which on cloud VMs is often
# a small root disk. Move them to the big disk, leaving links behind.
data="${VHOSTY_DATA_DIR:-auto}"
if [ "$data" = "auto" ]; then
  if command -v mountpoint >/dev/null 2>&1 && mountpoint -q /data; then data="/data"; else data="none"; fi
fi
if [ -n "$services" ] && ! command -v docker >/dev/null 2>&1; then
  step "Docker"
  curl -fsSL https://get.docker.com | sudo sh >/dev/null
  sudo usermod -aG docker "$USER"
  ok "installed $(docker --version 2>/dev/null | cut -d, -f1)"
fi
if [ "$data" != "none" ] && command -v docker >/dev/null 2>&1; then
  step "Docker data on $data"
  moved=""
  for d in docker containerd; do
    [ -L "/var/lib/$d" ] || moved="$moved $d"
  done
  if [ -n "$moved" ]; then
    sudo systemctl stop docker.socket docker containerd 2>/dev/null || true
    for d in $moved; do
      sudo mkdir -p "$data/$d"
      if [ -d "/var/lib/$d" ]; then sudo cp -a "/var/lib/$d/." "$data/$d/"; sudo rm -rf "/var/lib/$d"; fi
      sudo ln -s "$data/$d" "/var/lib/$d"
    done
    sudo systemctl start containerd docker
  fi
  ok "images and volumes in $data/docker and $data/containerd"
fi

step "Tailscale"
if ! command -v tailscale >/dev/null 2>&1; then
  curl -fsSL https://tailscale.com/install.sh | sh >/dev/null 2>&1 || die "Couldn't install Tailscale"
fi
if ! tailscale ip -4 >/dev/null 2>&1; then
  ask_secret TS_AUTHKEY "Tailscale auth key (login.tailscale.com → Settings → Keys)"
  key="$(mktemp)"; ( umask 077; printf '%s' "$TS_AUTHKEY" >"$key" )
  sudo tailscale up --auth-key="file:$key" --hostname="${TS_HOSTNAME:-$(hostname)}" --accept-dns=false \
    || { rm -f "$key"; die "Tailscale didn't accept that auth key"; }
  rm -f "$key"
fi
ok "on your tailnet as $(tailscale status --json 2>/dev/null | jq -r '.Self.HostName // empty') ($(tailscale ip -4 | head -1))"

step "vhosty"
if [ -x "$VHOSTY_BIN/vhosty" ]; then
  if [ -n "${VHOSTY_REF:-}" ]; then vhosty update self --ref "$VHOSTY_REF" --force; else vhosty update self; fi
else
  curl -fsSL "https://raw.githubusercontent.com/$REPO/main/install.sh" | VHOSTY_REF="${VHOSTY_REF:-}" bash | grep -E '✓|!|error' || true
  [ -x "$VHOSTY_BIN/vhosty" ] || die "vhosty didn't install"
  ok "$(vhosty version)"
fi

if [ "$php" != "off" ]; then
  step "PHP"
  if [ -z "$php" ]; then
    php="$(apt-cache search --names-only '^php[0-9]+\.[0-9]+-fpm$' 2>/dev/null \
      | sed -E 's/^php([0-9]+\.[0-9]+)-fpm.*/\1/' | sort -t. -k1,1n -k2,2n | tail -1)"
    [ -n "$php" ] || die "apt has no PHP-FPM. Set VHOSTY_PHP=off, or add the PHP repo: https://packages.sury.org/php/README.txt"
  fi
  if [ -x "/usr/sbin/php-fpm$php" ]; then ok "PHP $php already installed"; else quiet vhosty php install "$php"; fi
fi

if [ ! -d "$park" ]; then
  mkdir -p "$park/hello"
  cat >"$park/hello/index.html" <<EOF
<!doctype html>
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>hello.$domain</title>
<body style="font: 18px/1.5 system-ui, sans-serif; padding: 40px">
<h1>It works</h1>
<p>This is <code>$park/hello</code> on $(hostname), served by vhosty over your tailnet.
Every folder in <code>$park</code> is a site like this one.</p>
EOF
fi

step "vhosty setup"
if [ -z "$CF_API_TOKEN" ] && [ -f "$HOME/.vhosty/.env" ]; then # set up before: reuse its token
  CF_API_TOKEN="$(sed -n 's/^CF_API_TOKEN=//p' "$HOME/.vhosty/.env" | head -1)"
fi
ask_secret CF_API_TOKEN "Cloudflare API token (Zone Read, DNS Edit)"
export CF_API_TOKEN
if [ "$php" = "off" ]; then phpflag="--no-php"; else phpflag="--php"; fi
vhosty setup --domain "$domain" --park "$park" "$phpflag" --yes

if [ -n "$services" ]; then
  step "Docker services: $services"
  # A user just added to the docker group only gets it in a new login
  dk() { if docker info >/dev/null 2>&1; then "$@"; else sg docker -c "$(printf '%q ' "$@")"; fi; }
  if [ -f "$HOME/.vhosty/services/compose.yaml" ]; then ok "already set up in ~/.vhosty/services"
  else quiet dk vhosty services init --only "$services"; fi
  quiet dk vhosty services up
fi

step "Checking"
vhosty doctor || true

printf "\n%sDone.%s Sites in %s are live at https://<folder>.%s\n" "$B" "$N" "$park" "$domain"
[ ! -d "$park/hello" ] || printf "Try it from any device on your tailnet: https://hello.%s\n" "$domain"
}

main "$@"
