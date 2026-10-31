#!/usr/bin/env bash
#
# Creates a vhosty box on InstaBox (https://instabox.sh), from your own computer:
#
#   curl -fsSL https://raw.githubusercontent.com/vhostyhq/vhosty/main/scripts/instabox.sh \
#     | bash -s -- --name alice --domain alice.example.com
#
# It creates the machine (always on, 8 vCPU / 16 GB and a 100 GB disk, where
# your plan allows), hands it your tokens through the instabox CLI, and runs
# scripts/box-setup.sh on it: Tailscale, vhosty, PHP, Docker on the big disk.
#
# Options:
#   --name N         machine name, also its name on your tailnet (required)
#   --domain D       its domain, on Cloudflare (default: N.<your vhosty domain>,
#                    when this computer has vhosty set up)
#   --size C/G       vCPUs/GB of memory (default 8/16, else the biggest your plan has)
#   --disk GB        disk for home and Docker (default 100; paid plans)
#   --services LIST  Docker services to set up, like mysql,valkey
#   --php V          PHP version (default: the newest Debian offers); --no-php for none
#   --ref R          vhosty version on the box: a tag, or main (default: the latest release)
#   --reuse-token    use this computer's Cloudflare token (~/.vhosty/.env) for the box
#
# Tokens: CF_API_TOKEN and TS_AUTHKEY, asked for when they aren't set. They go to
# the machine over the instabox CLI, never on a command line. The Cloudflare token
# is stored on the box, so a separate one for it is safer than your main one. For a
# box you'll throw away, make the Tailscale key ephemeral.
#
# Needs Node.js (for npx) and the instabox CLI signed in (npx instabox@latest login),
# or INSTABOX_API_KEY. Written for the bash that ships with macOS (3.2).

set -euo pipefail

REPO="${VHOSTY_REPO:-vhostyhq/vhosty}"

if [ -t 1 ]; then B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; D=$'\033[2m'; N=$'\033[0m'
else B=""; G=""; Y=""; R=""; D=""; N=""; fi
ok()   { printf "  %s✓%s %s\n" "$G" "$N" "$*"; }
warn() { printf "  %s!%s %s\n" "$Y" "$N" "$*"; }
info() { printf "  %s%s%s\n" "$D" "$*" "$N"; }
step() { printf "\n%s→ %s%s\n" "$B" "$*" "$N"; }
die()  { printf "%serror:%s %s\n" "$R" "$N" "$*" >&2; exit 1; }

usage="Usage: instabox.sh --name N [--domain D] [--size C/G] [--disk GB] [--services LIST] [--php V | --no-php] [--ref R] [--reuse-token]"

# The instabox CLI: installed, or a known version through npx (your keys pass
# through it, so not whatever is newest). ib never reads this script's stdin;
# ib_in is for the commands that are handed input on purpose.
INSTABOX_CLI="${VHOSTY_INSTABOX_CLI:-instabox@0.8.85}"
ib_in() {
  if command -v instabox >/dev/null 2>&1; then instabox "$@"
  else npx -y "$INSTABOX_CLI" "$@"; fi
}
ib() { ib_in "$@" </dev/null; }

has_tty() { { : </dev/tty; } 2>/dev/null; }

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
  local name="" domain="" size="8/16" disk="100" services="" php="" ref="" reuse_token=0 d specs c g out free jid env cmd
  while [ $# -gt 0 ]; do
    case "$1" in
      --name)     name="${2:-}"; shift 2 ;;
      --domain)   domain="${2:-}"; shift 2 ;;
      --size)     size="${2:-}"; shift 2 ;;
      --disk)     disk="${2:-}"; shift 2 ;;
      --services) services="${2:-}"; shift 2 ;;
      --php)      php="${2:-}"; shift 2 ;;
      --no-php)   php="off"; shift ;;
      --ref)      ref="${2:-}"; shift 2 ;;
      --reuse-token) reuse_token=1; shift ;;
      -h|--help)  echo "$usage"; exit 0 ;;
      *) die "$usage" ;;
    esac
  done
  [ -n "$name" ] || die "$usage"
  printf '%s' "$name" | grep -qE '^[a-z0-9]([a-z0-9-]*[a-z0-9])?$' || die "--name: use lowercase letters, numbers and dashes"
  printf '%s' "$size" | grep -qE '^[0-9]+/[0-9]+$' || die "--size: vCPUs/GB, like 8/16"
  printf '%s' "$disk" | grep -qE '^[0-9]+$' || die "--disk: GB, like 100"
  if [ -z "$domain" ] && [ -f "$HOME/.vhosty/config" ]; then
    d="$(sed -n 's/^VHOSTY_DOMAIN="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$HOME/.vhosty/config" | head -1)"
    [ -z "$d" ] || domain="$name.$d"
  fi
  [ -n "$domain" ] || die "--domain is required (no vhosty domain on this computer to build one from)"

  printf "%svhosty on InstaBox%s  %s → *.%s\n" "$B" "$N" "$name" "$domain"

  step "InstaBox"
  command -v instabox >/dev/null 2>&1 || command -v npx >/dev/null 2>&1 || die "Needs Node.js, for npx: https://nodejs.org"
  out="$(ib whoami 2>&1)" || die "Sign in to InstaBox first: npx instabox@latest login (or set INSTABOX_API_KEY)"
  ok "signed in: $(printf '%s' "$out" | head -1)"
  if ib get "$name" >/dev/null 2>&1; then die "There's already a machine called $name (instabox ls)"; fi

  step "Tokens"
  # The token is stored on the box, a machine coding agents work on, and a
  # Cloudflare token can't be limited to a subdomain: it can edit the whole
  # zone. So a separate one is better than this computer's, which is only
  # reused when asked.
  if [ -z "${CF_API_TOKEN:-}" ] && [ "$reuse_token" = "1" ] && [ -f "$HOME/.vhosty/.env" ]; then
    CF_API_TOKEN="$(sed -n 's/^CF_API_TOKEN=//p' "$HOME/.vhosty/.env" | head -1)"
    [ -z "$CF_API_TOKEN" ] || ok "Cloudflare token from ~/.vhosty/.env (--reuse-token)"
  fi
  [ -n "${CF_API_TOKEN:-}" ] || info "A Cloudflare token just for this box is safer than your main one: it will live on the box."
  ask_secret CF_API_TOKEN "Cloudflare API token (Zone Read, DNS Edit)"
  ask_secret TS_AUTHKEY "Tailscale auth key (login.tailscale.com → Settings → Keys)"
  ok "Cloudflare and Tailscale"

  step "Machine"
  # The plan decides the sizes; take the one asked for, else the biggest
  specs="$(ib usage --json 2>/dev/null | node -e '
    let s = ""; process.stdin.on("data", d => s += d).on("end", () => {
      for (const m of JSON.parse(s).limits.machineSpecs || []) console.log(m.vcpus + "/" + m.memMiB / 1024);
    })' 2>/dev/null || true)"
  if [ -n "$specs" ] && ! printf '%s\n' "$specs" | grep -qx "$size"; then
    c="$(printf '%s\n' "$specs" | sort -t/ -k1,1n -k2,2n | tail -1)"
    warn "your plan has no $size; using $c"
    size="$c"
  fi
  c="${size%/*}"; g="${size#*/}"
  info "creating $name ($c vCPU, $g GB)"
  free=0
  if ! out="$(ib create --name "$name" --vcpus "$c" --mem-mib $((g * 1024)) --auto-suspend 0 2>&1)"; then
    case "$out" in
      *permission_denied*|*spec_not_allowed*)
        free=1
        warn "the free plan's machines are fixed: 4 vCPU, 8 GB, 20 GB disk, and they pause after"
        warn "30 idle minutes (and after 8 hours). For a box you can always reach, use Pro."
        out="$(ib create --name "$name" 2>&1)" || die "Couldn't create $name: $out" ;;
      *) die "Couldn't create $name: $out" ;;
    esac
  fi
  if [ "$free" = "0" ]; then ok "created $name: $c vCPU, $g GB, always on"; else ok "created $name: 4 vCPU, 8 GB"; fi
  if [ "$free" = "0" ] && [ "$disk" -gt 20 ]; then
    if out="$(ib resize "$name" --disk "$disk" 2>&1)"; then ok "disk: $disk GB"
    else warn "couldn't grow the disk to $disk GB: $(printf '%s' "$out" | tail -1)"; fi
  fi

  step "Setting up the box (a few minutes)"
  # Tokens go in a file only the machine's user can read; box-setup reads it and deletes it
  printf 'CF_API_TOKEN=%s\nTS_AUTHKEY=%s\n' "$CF_API_TOKEN" "$TS_AUTHKEY" \
    | ib_in exec "$name" --stdin -- 'umask 077; cat > ~/.vhosty-box-secrets' >/dev/null \
    || die "Couldn't hand the tokens to $name"
  env="VHOSTY_SECRETS_FILE=\$HOME/.vhosty-box-secrets VHOSTY_DOMAIN=$(printf '%q' "$domain") TS_HOSTNAME=$(printf '%q' "$name")"
  [ -z "$services" ] || env="$env VHOSTY_SERVICES=$(printf '%q' "$services")"
  [ -z "$php" ] || env="$env VHOSTY_PHP=$(printf '%q' "$php")"
  [ -z "$ref" ] || env="$env VHOSTY_REF=$(printf '%q' "$ref")"
  if [ -n "${VHOSTY_BOX_SETUP:-}" ]; then # a local box-setup.sh, for working on it
    ib_in exec "$name" --stdin -- 'cat > ~/.vhosty-box-setup.sh' <"$VHOSTY_BOX_SETUP" >/dev/null || die "Couldn't copy $VHOSTY_BOX_SETUP"
    cmd="$env bash ~/.vhosty-box-setup.sh"
  else
    cmd="curl -fsSL https://raw.githubusercontent.com/$REPO/main/scripts/box-setup.sh | $env bash"
  fi
  # A job, not a plain exec: exec stops at 10 minutes, and Docker images can take longer
  jid="$(ib exec --background "$name" -- "$cmd" 2>/dev/null | head -1)"
  if [ -z "$jid" ]; then
    ib exec "$name" -- 'rm -f ~/.vhosty-box-secrets' >/dev/null 2>&1 || true
    die "Couldn't start the setup on $name"
  fi
  if ! ib jobs logs "$name" "$jid" -f; then
    # box-setup deletes the tokens once it reads them; it may not have got that far
    ib exec "$name" -- 'rm -f ~/.vhosty-box-secrets' >/dev/null 2>&1 || true
    printf '\n'
    die "Setup on $name failed (see above). Fix it and run again on the box: instabox ssh $name, then: $cmd"
  fi

  printf "\n%s%s is ready.%s Its sites are at https://<folder>.%s\n" "$B" "$name" "$N" "$domain"
  printf "  Open: https://hello.%s (from any device on your tailnet)\n" "$domain"
  printf "  Work on it: instabox ssh %s, or point your editor at it over SSH\n" "$name"
}

main "$@"
