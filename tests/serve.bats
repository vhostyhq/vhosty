#!/usr/bin/env bats
# Caddy behind Tailscale Serve, the same on Linux and macOS: Caddy on
# localhost's high ports, Serve passing the tailnet's 443 and 80 to them with a
# PROXY header. Each test runs as both platforms (`on`), whichever one the
# tests run on.

load helpers

# Found before vhosty_setup points HOME at a scratch folder
CADDY="${VHOSTY_TEST_CADDY:-$HOME/.vhosty/bin/caddy}"

PLATFORMS="linux mac"

# A fake tailscale whose Serve config is kept as "port target [proxy-protocol]"
# lines, and printed as JSON the way the real one prints it. serve_stub [JSON]
# starts from that JSON instead (something else on Serve).
serve_stub() {
  : >"$HOME/serve.tcp"
  rm -f "$HOME/tailscale.log"
  if [ -n "${1:-}" ]; then printf '%s\n' "$1" >"$HOME/serve.json"; else echo '{}' >"$HOME/serve.json"; fi
  stub tailscale '
tcp="$HOME/serve.tcp"; st="$HOME/serve.json"
echo "$*" >>"$HOME/tailscale.log"
write() {
  { printf "{\n  \"TCP\": {"; sep=""
    while read -r p t pp; do
      printf "%s\n    \"%s\": {\n      \"TCPForward\": \"%s\"" "$sep" "$p" "$t"
      [ -z "$pp" ] || printf ",\n      \"ProxyProtocol\": %s" "$pp"
      printf "\n    }"; sep=","
    done <"$tcp"
    printf "\n  }\n}\n"; } >"$st"
}
case "$*" in
  ip*) echo 100.64.0.7 ;;
  "serve status --json") cat "$st" ;;
  "serve status") echo "(serve status)" ;;
  "serve --bg --tcp="*" --proxy-protocol=2 tcp://"*)
    p="${3#--tcp=}"; grep -v "^$p " "$tcp" >"$tcp.new"; echo "$p ${5#tcp://} 2" >>"$tcp.new"; mv "$tcp.new" "$tcp"; write ;;
  "serve --https="*" off"|"serve --http="*" off"|"serve --tcp="*" off")
    p="${2#*=}"; grep -v "^$p " "$tcp" >"$tcp.new" || true; mv "$tcp.new" "$tcp"; write ;;
  *) echo "unexpected: $*" >&2; exit 1 ;;
esac'
}

# serve_has "443 127.0.0.1:48443 [2]" ...: Serve's forwards, as the stub keeps them
serve_has() {
  local l
  for l in "$@"; do grep -qx "$l" "$HOME/serve.tcp" || { echo "no forward: $l" >&2; cat "$HOME/serve.tcp" >&2; return 1; }; done
}

# vhosty's forwards from before the PROXY header
old_forwards() {
  serve_stub
  printf '443 127.0.0.1:48443\n80 127.0.0.1:48080\n' >"$HOME/serve.tcp"
  printf '{"TCP":{"443":{"TCPForward":"127.0.0.1:48443"},"80":{"TCPForward":"127.0.0.1:48080"}}}\n' >"$HOME/serve.json"
}

# T3 Code paired over Tailscale, which publishes itself on 443 unless told otherwise
T3_ON_443='{"TCP":{"443":{"HTTPS":true},"8443":{"HTTPS":true}},"Web":{"box.tail1.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:3773"}}},"box.tail1.ts.net:8443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:3773"}}}}}'

# --- the Caddyfile ------------------------------------------------------------

@test "Caddy listens on localhost's 48443 and 48080 only, and redirects http itself" {
  for p in $PLATFORMS; do
    $p write_configs
    caddyfile="$(cat "$VHOSTY_DIR/Caddyfile")"
    run grep -E '^\s*default_bind' "$VHOSTY_DIR/Caddyfile"
    [ "$output" = "$(printf '\tdefault_bind 127.0.0.1')" ]
    refute_contains "$caddyfile" "100.64.0.7"
    assert_contains "$caddyfile" "https_port 48443"
    assert_contains "$caddyfile" "http_port 48080"
    assert_contains "$caddyfile" "auto_https disable_redirects"
    assert_contains "$caddyfile" "http://*.test.example {
	redir https://{host}{uri} permanent
}"
  done
}

@test "Caddy reads Serve's PROXY header, from 127.0.0.1 only, before TLS" {
  for p in $PLATFORMS; do
    $p write_configs
    assert_contains "$(cat "$VHOSTY_DIR/Caddyfile")" "		listener_wrappers {
			proxy_protocol {
				allow 127.0.0.1/32
			}
			tls
		}"
  done
}

@test "the Caddyfile is the same on Linux and macOS" {
  php_site app
  linux write_configs
  on_linux="$(cat "$VHOSTY_DIR/Caddyfile")"
  mac write_configs
  [ "$(cat "$VHOSTY_DIR/Caddyfile")" = "$on_linux" ]
}

@test "the ports are settings, saved with the config" {
  write_config 'VHOSTY_SERVE_PORT="49443"
VHOSTY_SERVE_HTTP_PORT="49080"'
  for p in $PLATFORMS; do
    $p write_configs
    assert_contains "$(cat "$VHOSTY_DIR/Caddyfile")" "https_port 49443"
    [ "$($p serve_pairs)" = "443:49443 80:49080" ]
  done
  write_config
  for p in $PLATFORMS; do
    $p save_config
    grep -q '^VHOSTY_SERVE_PORT=48443$' "$VHOSTY_DIR/config"
    grep -q '^VHOSTY_SERVE_HTTP_PORT=48080$' "$VHOSTY_DIR/config"
  done
}

@test "the Caddyfile doesn't depend on the Tailscale address" {
  for p in $PLATFORMS; do
    stub tailscale 'case "$1" in ip) echo 100.64.0.7 ;; esac'
    $p write_configs
    before="$(cat "$VHOSTY_DIR/Caddyfile")"
    stub tailscale 'case "$1" in ip) echo 100.64.0.99 ;; esac'
    $p write_configs
    [ "$(cat "$VHOSTY_DIR/Caddyfile")" = "$before" ]
    run $p drift_reason
    [ "$output" = "settings changed since the last rebuild" ]
  done
}

@test "the Caddyfile is valid" {
  [ -x "$CADDY" ] || skip "no Caddy with the Cloudflare plugin (set VHOSTY_TEST_CADDY)"
  php_site app
  for p in $PLATFORMS; do
    $p write_configs
    CF_API_TOKEN=0123456789abcdef0123456789abcdef01234567 run "$CADDY" validate --config "$VHOSTY_DIR/Caddyfile" --adapter caddyfile
    [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  done
}

# --- Tailscale Serve ----------------------------------------------------------

@test "Tailscale Serve passes the tailnet's 443 and 80 to Caddy, with the PROXY header" {
  for p in $PLATFORMS; do
    serve_stub
    $p serve_on
    $p serve_ok
    log="$(cat "$HOME/tailscale.log")"
    assert_contains "$log" "serve --bg --tcp=443 --proxy-protocol=2 tcp://127.0.0.1:48443"
    assert_contains "$log" "serve --bg --tcp=80 --proxy-protocol=2 tcp://127.0.0.1:48080"
  done
}

@test "Tailscale Serve already passing both ports to Caddy is left alone" {
  for p in $PLATFORMS; do
    serve_stub '{"TCP":{"443":{"TCPForward":"127.0.0.1:48443","ProxyProtocol":2},"80":{"TCPForward":"127.0.0.1:48080","ProxyProtocol":2}}}'
    $p serve_on
    refute_contains "$(cat "$HOME/tailscale.log")" "--bg"
  done
}

@test "vhosty's forwards from before the PROXY header are replaced without asking" {
  for p in $PLATFORMS; do
    old_forwards
    run $p serve_ok
    [ "$status" -ne 0 ]
    run $p serve_on </dev/null
    [ "$status" -eq 0 ]
    refute_contains "$output" "already uses"
    serve_has "443 127.0.0.1:48443 2" "80 127.0.0.1:48080 2"
  done
}

@test "an older setup with only 443 on Serve gets 80 added" {
  for p in $PLATFORMS; do
    serve_stub
    printf '443 127.0.0.1:48443 2\n' >"$HOME/serve.tcp"
    printf '{"TCP":{"443":{"TCPForward":"127.0.0.1:48443","ProxyProtocol":2}}}\n' >"$HOME/serve.json"
    run $p serve_on
    [ "$status" -eq 0 ]
    refute_contains "$output" "already uses"
    log="$(cat "$HOME/tailscale.log")"
    refute_contains "$log" "--tcp=443 --proxy"
    assert_contains "$log" "serve --bg --tcp=80 --proxy-protocol=2 tcp://127.0.0.1:48080"
    $p serve_ok
  done
}

@test "something else on Tailscale Serve's 443 is replaced, once you say yes" {
  for p in $PLATFORMS; do
    serve_stub "$T3_ON_443"
    run $p serve_on </dev/null   # no terminal: the default, yes
    [ "$status" -eq 0 ]
    assert_contains "$output" "already uses port 443"
    assert_contains "$output" "Replacing it turns that off"
    assert_contains "$output" "tailscale serve --bg --https=8443 http://127.0.0.1:3773"
    assert_contains "$(cat "$HOME/tailscale.log")" "serve --https=443 off"
    $p serve_ok
  done
}

@test "doctor says what took vhosty's 443 on Serve, and how to move it" {
  for p in $PLATFORMS; do
    serve_stub "$T3_ON_443"
    run $p serve_check
    assert_contains "$output" "port 443 goes to http://127.0.0.1:3773, not vhosty's Caddy"
    assert_contains "$output" "tailscale serve --https=443 off"
    assert_contains "$output" "tailscale serve --bg --https=8443 http://127.0.0.1:3773"
    # doctor only looks
    refute_contains "$(cat "$HOME/tailscale.log")" "off"
  done
}

@test "doctor names another TCP forward on 443 too" {
  serve_stub '{"TCP":{"443":{"TCPForward":"127.0.0.1:9443"}}}'
  run linux serve_check
  assert_contains "$output" "port 443 goes to tcp://127.0.0.1:9443"
  assert_contains "$output" "tailscale serve --tcp=443 off"
}

@test "doctor sends vhosty's own forwards without the PROXY header to rebuild" {
  old_forwards
  run linux serve_check
  assert_contains "$output" "isn't passing ports 443 and 80 to Caddy"
  assert_contains "$output" "vhosty rebuild"
}

@test "Tailscale Serve refusing stops with its message, and on Linux says how to allow it" {
  stub tailscale 'case "$*" in ip*) echo 100.64.0.7 ;; "serve status --json") echo "{}" ;; *) echo "Access denied: serve config denied" >&2; exit 1 ;; esac'
  run linux serve_on
  [ "$status" -ne 0 ]
  assert_contains "$output" "Access denied"
  assert_contains "$output" "sudo tailscale set --operator="
  run mac serve_on
  [ "$status" -ne 0 ]
  refute_contains "$output" "--operator"
}

@test "Tailscale Serve not enabled on the tailnet stops with its message" {
  stub tailscale 'case "$*" in ip*) echo 100.64.0.7 ;; "serve status --json") echo "{}" ;; *) echo "Serve is not enabled on your tailnet. To enable, visit: https://login.tailscale.com/f/serve" >&2; exit 1 ;; esac'
  for p in $PLATFORMS; do
    run $p serve_on
    [ "$status" -ne 0 ]
    assert_contains "$output" "Serve is not enabled on your tailnet"
  done
}

@test "a Tailscale without --proxy-protocol says to update it" {
  stub tailscale 'case "$*" in ip*) echo 100.64.0.7 ;; "serve status --json") echo "{}" ;; *) echo "flag provided but not defined: -proxy-protocol" >&2; exit 2 ;; esac'
  for p in $PLATFORMS; do
    run $p serve_on
    [ "$status" -ne 0 ]
    assert_contains "$output" "Update Tailscale"
  done
}

@test "uninstall's Serve cleanup only removes vhosty's forwards, old or new" {
  for p in $PLATFORMS; do
    serve_stub "$T3_ON_443"
    $p serve_off
    [ ! -f "$HOME/tailscale.log" ] || refute_contains "$(cat "$HOME/tailscale.log")" "off"
    serve_stub
    printf '443 127.0.0.1:48443\n80 127.0.0.1:48080 2\n' >"$HOME/serve.tcp"
    printf '{"TCP":{"443":{"TCPForward":"127.0.0.1:48443"},"80":{"TCPForward":"127.0.0.1:48080","ProxyProtocol":2}}}\n' >"$HOME/serve.json"
    $p serve_off
    log="$(cat "$HOME/tailscale.log")"
    assert_contains "$log" "serve --tcp=443 off"
    assert_contains "$log" "serve --tcp=80 off"
  done
}

@test "on Linux, setup makes you Tailscale's operator once, so Serve needs no sudo" {
  stub sudo 'echo "sudo $*" >>"$HOME/sudo.log"'
  stub tailscale 'case "$*" in "debug prefs") printf "{\n\t\"OperatorUser\": \"\"\n}\n" ;; esac'
  linux serve_allow_user
  assert_contains "$(cat "$HOME/sudo.log")" "set --operator=$USER"
  rm "$HOME/sudo.log"
  stub tailscale "case \"\$*\" in \"debug prefs\") printf '{\n\t\"OperatorUser\": \"$USER\"\n}\n' ;; esac"
  linux serve_allow_user
  [ ! -f "$HOME/sudo.log" ]
  # macOS's Tailscale app needs no operator
  stub tailscale 'case "$*" in "debug prefs") printf "{\n\t\"OperatorUser\": \"\"\n}\n" ;; esac'
  mac serve_allow_user
  [ ! -f "$HOME/sudo.log" ]
}
