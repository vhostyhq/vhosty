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
  sed -e "s/^\tdefault_bind .*/\tadmin off\n\tauto_https off\n\tdefault_bind 127.0.0.1/" \
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
  run get 59999
  [ "$(echo "$output" | tail -1)" = 502 ]
  assert_contains "$output" "Nothing is running on port 59999"
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
