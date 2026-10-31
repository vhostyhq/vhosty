# Shared setup for the bats tests: a scratch home with its own ~/.vhosty, a
# fake tailscale, and `vh` to call bin/vhosty's functions.

ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

# Test files can define their own setup that calls vhosty_setup
setup() { vhosty_setup; }

vhosty_setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  export VHOSTY_DIR="$HOME/.vhosty"
  export XDG_CONFIG_HOME="$HOME/.config" XDG_DATA_HOME="$HOME/.local/share"
  unset SUDO_USER VHOSTY_PHP_VERSION CF_API_TOKEN
  mkdir -p "$VHOSTY_DIR/sites" "$HOME/stubs"
  PARKED="$HOME/Sites"
  mkdir -p "$PARKED"
  # A tailnet address without a tailnet
  stub tailscale 'case "$1" in ip) echo 100.64.0.7 ;; esac'
  export PATH="$HOME/stubs:$PATH"
  write_config
}

# stub NAME 'body': a fake command, first on the PATH
stub() {
  printf '#!/usr/bin/env bash\n%s\n' "$2" >"$HOME/stubs/$1"
  chmod +x "$HOME/stubs/$1"
}

# write_config [extra lines]: a typical config, parking $PARKED
write_config() {
  cat >"$VHOSTY_DIR/config" <<EOF
VHOSTY_DOMAIN="test.example"
VHOSTY_PARKED="$PARKED"
VHOSTY_PHP="on"
VHOSTY_PHP_DEFAULT="8.4"
${1:-}
EOF
}

# vh FUNCTION [ARGS...]: runs one of bin/vhosty's functions in a fresh bash
# with the script's own options (set -euo pipefail) and the scratch config
vh() {
  VHOSTY_SRC="$ROOT/bin/vhosty" "${VHOSTY_TEST_BASH:-bash}" -c 'source "$VHOSTY_SRC"; trap cleanup_tmp EXIT; load_config; "$@"' vh "$@"
}

# site_conf NAME 'KEY=value lines': writes ~/.vhosty/sites/NAME.conf
site_conf() {
  printf '%s\n' "$2" >"$VHOSTY_DIR/sites/$1.conf"
}

# php_site NAME / static_site NAME: a folder in the parked directory
php_site()    { mkdir -p "$PARKED/$1/public"; echo '<?php' >"$PARKED/$1/public/index.php"; }
static_site() { mkdir -p "$PARKED/$1"; echo '<h1>hi</h1>' >"$PARKED/$1/index.html"; }

# assert_contains HAYSTACK NEEDLE / refute_contains: with the text shown on failure
assert_contains() {
  case "$1" in *"$2"*) return 0 ;; esac
  printf 'expected to find:\n  %s\nin:\n%s\n' "$2" "$1" >&2
  return 1
}
refute_contains() {
  case "$1" in *"$2"*) printf 'expected not to find:\n  %s\nin:\n%s\n' "$2" "$1" >&2; return 1 ;; esac
}
