#!/usr/bin/env bats
# The generated Caddyfile, run by a real Caddy: routing and the error pages.
# Needs Caddy with the Cloudflare DNS plugin: $VHOSTY_TEST_CADDY, or the one
# vhosty installed (~/.vhosty/bin/caddy). Skipped without one.

load helpers

PORT=18443

# Found before vhosty_setup points HOME at a scratch folder
CADDY="${VHOSTY_TEST_CADDY:-$HOME/.vhosty/bin/caddy}"

setup() {
  [ -x "$CADDY" ] || skip "no Caddy with the Cloudflare plugin (set VHOSTY_TEST_CADDY)"
  vhosty_setup
}

teardown() {
  [ -z "${CADDY_PID:-}" ] || kill "$CADDY_PID" 2>/dev/null || true
}

# Runs the generated config over plain HTTP on a high port, with no certificate
start_caddy() {
  vh write_configs
  sed -e '/^\tadmin /d' -e "s/^\tdefault_bind .*/\tadmin off\n\tauto_https off\n\tdefault_bind 127.0.0.1/" \
      -e "s/^\*\.test\.example {/http:\/\/*.test.example:$PORT {/" \
      -e '/^\ttls {/,/^\t}/d' "$VHOSTY_DIR/Caddyfile" >"$HOME/test.Caddyfile"
  "$CADDY" run --config "$HOME/test.Caddyfile" --adapter caddyfile >"$HOME/caddy.log" 2>&1 &
  CADDY_PID=$!
  for _ in $(seq 1 50); do
    curl -s -o /dev/null "http://127.0.0.1:$PORT/" -H "Host: x.test.example" && return 0
    sleep 0.1
  done
  cat "$HOME/caddy.log" >&2
  return 1
}

# get NAME [PATH]: "<status>" then the body
get() { curl -s -w '\n%{http_code}' -H "Host: $1.test.example" "http://127.0.0.1:$PORT${2:-/}"; }

@test "the generated Caddyfile is valid" {
  vh write_configs
  # a token of the right shape; validate checks its format, not with Cloudflare
  CF_API_TOKEN=0123456789abcdef0123456789abcdef01234567 run "$CADDY" validate --config "$VHOSTY_DIR/Caddyfile" --adapter caddyfile
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
}

@test "a static parked folder is served" {
  static_site hello
  start_caddy
  run get hello
  [ "$(echo "$output" | tail -1)" = 200 ]
  assert_contains "$output" "<h1>hi</h1>"
}

@test "a name with no site gets the 404 page, listing the sites that work" {
  static_site hello
  static_site other
  start_caddy
  run get nosuch
  [ "$(echo "$output" | tail -1)" = 404 ]
  assert_contains "$output" "No site called <code>nosuch</code>"
  assert_contains "$output" "https://hello.test.example/"
  assert_contains "$output" "https://other.test.example/"
}

@test "a folder without an entry file is called out on the 404 page" {
  mkdir -p "$PARKED/empty"
  start_caddy
  run get empty
  assert_contains "$output" "exists, but has no"
}

@test "a port with nothing listening gets the 502 page, which reloads itself" {
  start_caddy
  run get 5998
  [ "$(echo "$output" | tail -1)" = 502 ]
  assert_contains "$output" "Nothing is running on port 5998"
  assert_contains "$output" '<meta http-equiv="refresh" content="2">'
}

@test "PHP being down gets the 502 page with the commands to fix it" {
  php_site escrow
  start_caddy
  run get escrow /dashboard
  [ "$(echo "$output" | tail -1)" = 502 ]
  assert_contains "$output" "PHP 8.4 isn't answering"
  assert_contains "$output" "vhosty restart php-8.4"
}

@test "a missing file inside a site keeps Caddy's plain 404" {
  static_site hello
  start_caddy
  run get hello /missing.css
  [ "$(echo "$output" | tail -1)" = 404 ]
  refute_contains "$output" "vhosty"
}

@test "the request's host is escaped on the error page" {
  start_caddy
  run curl -s -H 'Host: <b>x.test.example' "http://127.0.0.1:$PORT/"
  refute_contains "$output" "<b>x"
}

@test "a static site doesn't serve dotfiles, but does serve .well-known" {
  static_site front
  echo "SECRET=1" >"$PARKED/front/.env"
  mkdir -p "$PARKED/front/.git" "$PARKED/front/assets/.cache" "$PARKED/front/.well-known"
  echo "[core]" >"$PARKED/front/.git/config"
  echo "x" >"$PARKED/front/assets/.cache/x"
  echo "contact" >"$PARKED/front/.well-known/security.txt"
  start_caddy
  for p in /.env /.git/config /assets/.cache/x /%2eenv; do
    run get front "$p"
    [ "$(echo "$output" | tail -1)" = 404 ] || { echo "$p: $output" >&2; false; }
    refute_contains "$output" "SECRET"
  done
  run get front /.well-known/security.txt
  [ "$(echo "$output" | tail -1)" = 200 ]
}

@test "a configured static site doesn't serve dotfiles either" {
  mkdir -p "$HOME/Projects/docs"
  echo "<h1>docs</h1>" >"$HOME/Projects/docs/index.html"
  echo "SECRET=1" >"$HOME/Projects/docs/.env"
  site_conf docs "SITE_PATH=$HOME/Projects/docs
SITE_LINKED=yes"
  start_caddy
  run get docs /.env
  [ "$(echo "$output" | tail -1)" = 404 ]
  run get docs /
  [ "$(echo "$output" | tail -1)" = 200 ]
}

@test "with a space in the home folder, Caddy sees one PHP-FPM upstream" {
  command -v jq >/dev/null || skip "no jq"
  export HOME="$BATS_TEST_TMPDIR/Jane Doe" VHOSTY_DIR="$BATS_TEST_TMPDIR/Jane Doe/.vhosty"
  PARKED="$HOME/Sites"
  mkdir -p "$VHOSTY_DIR/sites" "$PARKED"
  write_config
  php_site escrow
  site_conf escrow "SITE_PHP=8.4"
  vh write_caddyfile
  dials="$(CF_API_TOKEN=0123456789abcdef0123456789abcdef01234567 "$CADDY" adapt --config "$VHOSTY_DIR/Caddyfile" --adapter caddyfile 2>/dev/null \
    | jq -r '.. | .dial? // empty' | grep '^unix/' | sort -u)"
  [ "$dials" = "unix/$VHOSTY_DIR/run/php-8.4.sock" ] || { echo "upstreams: $dials" >&2; false; }
}

@test "the admin API is on a socket only the owner can use, and reloads work through it" {
  vh write_configs
  sed -e "s/^\tdefault_bind .*/\tauto_https off\n\tdefault_bind 127.0.0.1/" \
      -e "s/^\*\.test\.example {/http:\/\/*.test.example:$PORT {/" \
      -e '/^\ttls {/,/^\t}/d' "$VHOSTY_DIR/Caddyfile" >"$HOME/test.Caddyfile"
  "$CADDY" run --config "$HOME/test.Caddyfile" --adapter caddyfile >"$HOME/caddy.log" 2>&1 &
  CADDY_PID=$!
  for _ in $(seq 1 50); do [ -S "$VHOSTY_DIR/run/caddy-admin.sock" ] && break; sleep 0.1; done
  [ -S "$VHOSTY_DIR/run/caddy-admin.sock" ] || { cat "$HOME/caddy.log" >&2; false; }
  perms="$(ls -l "$VHOSTY_DIR/run/caddy-admin.sock" | cut -c1-10)"
  [ "$perms" = "srw-------" ] || { echo "socket: $perms" >&2; false; }
  run "$CADDY" reload --config "$HOME/test.Caddyfile" --adapter caddyfile --force
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
}

@test "a port outside VHOSTY_PORTS isn't proxied, and the page says how to open it" {
  start_caddy
  for port in 8125 2019 9200 99999999999999999999; do
    run get "$port"
    [ "$(echo "$output" | tail -1)" = 403 ] || { echo "$port: $output" >&2; false; }
  done
  run get 8125
  assert_contains "$output" "Port 8125 isn't open to your tailnet"
  assert_contains "$output" 'VHOSTY_PORTS="3000-5999 6006 8000-8099 8888 8125"'
}

@test "VHOSTY_PORTS opens the ports it lists" {
  write_config 'VHOSTY_PORTS="7000-7010 9200"'
  start_caddy
  run get 9200
  [ "$(echo "$output" | tail -1)" = 502 ]   # open, nothing listening
  run get 7005
  [ "$(echo "$output" | tail -1)" = 502 ]
  run get 5173
  [ "$(echo "$output" | tail -1)" = 403 ]
}
