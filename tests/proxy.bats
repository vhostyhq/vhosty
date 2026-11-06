#!/usr/bin/env bats
# vhosty proxy: app.domain → a port on this machine, for what isn't a PHP site.
# A proxy has no folder, so what walks the sites has to leave it alone. A small
# Python server stands in for the app, and ss and lsof are stubbed so what this
# machine really runs doesn't matter.

load helpers

APP_PORT=18491
PORT=18471

# Found before vhosty_setup points HOME at a scratch folder
CADDY="${VHOSTY_TEST_CADDY:-$HOME/.vhosty/bin/caddy}"

setup() {
  vhosty_setup
  nothing_listening
}

teardown() {
  local p
  for p in ${CADDY_PID:-} ${APP_PID:-}; do kill "$p" 2>/dev/null || true; done
}

nothing_listening() { stub ss 'exit 0'; stub lsof 'exit 0'; }

# listening PORT: a process called node on that port, and nothing on any other
listening() {
  stub ss "case \"\$*\" in *:$1\\ *) echo 'LISTEN 0 0 127.0.0.1:$1 0.0.0.0:* users:((\"node\",pid=1,fd=1))' ;; esac"
}

proxy_conf() { printf 'PROXY_PORT=%s\n' "$2" >"$HOME/p.conf"; mkdir -p "$VHOSTY_DIR/proxies"; mv "$HOME/p.conf" "$VHOSTY_DIR/proxies/$1.conf"; }

# --- vhosty proxy -------------------------------------------------------------

@test "proxy: saves the port and routes the name to it" {
  run linux main proxy grafana 3001
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  assert_contains "$output" "https://grafana.test.example → localhost:3001"
  grep -q '^PROXY_PORT=3001$' "$VHOSTY_DIR/proxies/grafana.conf"
  caddyfile="$(cat "$VHOSTY_DIR/Caddyfile")"
  assert_contains "$caddyfile" "@proxy_grafana host grafana.test.example"
  assert_contains "$caddyfile" "reverse_proxy localhost:3001"
  assert_contains "$caddyfile" "vhosty_kind proxy"
  assert_contains "$caddyfile" "vhosty_proxy_port 3001"
}

@test "proxy: the name is lowercased, as hostnames are" {
  run linux main proxy MyApp 3001
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [ -f "$VHOSTY_DIR/proxies/myapp.conf" ]
}

@test "proxy: says when nothing is listening yet, and does it anyway" {
  run linux main proxy grafana 3001
  [ "$status" -eq 0 ]
  assert_contains "$output" "nothing is listening on port 3001 yet"
  listening 3001
  run linux main proxy grafana 3001
  [ "$status" -eq 0 ]
  refute_contains "$output" "nothing is listening"
}

@test "proxy: run again with another port, it moves" {
  linux main proxy grafana 3001
  run linux main proxy grafana 3002
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  assert_contains "$(cat "$VHOSTY_DIR/Caddyfile")" "reverse_proxy localhost:3002"
  refute_contains "$(cat "$VHOSTY_DIR/Caddyfile")" "localhost:3001"
}

@test "proxy: two names can share a port" {
  linux main proxy one 3001
  run linux main proxy two 3001
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  assert_contains "$(cat "$VHOSTY_DIR/Caddyfile")" "@proxy_one host"
  assert_contains "$(cat "$VHOSTY_DIR/Caddyfile")" "@proxy_two host"
}

@test "proxy: names that aren't one DNS label are refused" {
  long="$(printf 'a%.0s' $(seq 1 64))"
  for bad in -app app- a.b a_b 'a b' 'a/b' '../sites/x' '' "$long" "$(printf 'a\nb')"; do
    run linux main proxy "$bad" 3001
    [ "$status" -ne 0 ] || { echo "accepted: $bad" >&2; false; }
    assert_contains "$output" "isn't a valid proxy name"
  done
  [ ! -d "$VHOSTY_DIR/proxies" ]
}

@test "proxy: a 63-character name is the longest allowed" {
  name="$(printf 'a%.0s' $(seq 1 63))"
  run linux main proxy "$name" 3001
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [ -f "$VHOSTY_DIR/proxies/$name.conf" ]
}

@test "proxy: an all-numeric name is refused, for the port route" {
  for bad in 3000 0 123456; do
    run linux main proxy "$bad" 3001
    [ "$status" -ne 0 ]
    assert_contains "$output" "clash with port URLs"
  done
  [ ! -d "$VHOSTY_DIR/proxies" ]
  run linux main proxy 3d 3001
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
}

@test "proxy: an invalid port is refused" {
  for bad in 0 65536 99999999999999999999 abc 03000 -1 3000.5 '3000 ' '' "$(printf '3000\n3001')"; do
    run linux main proxy grafana "$bad"
    [ "$status" -ne 0 ] || { echo "accepted: $bad" >&2; false; }
    assert_contains "$output" "isn't a port"
  done
  [ ! -d "$VHOSTY_DIR/proxies" ]
}

@test "proxy: the first and last ports are fine" {
  for good in 1 65535; do
    run linux main proxy "p$good" "$good"
    [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  done
}

@test "proxy: needs a name and a port, and no more" {
  for args in "" "grafana" "grafana 3001 extra"; do
    # shellcheck disable=SC2086
    run linux main proxy $args
    [ "$status" -ne 0 ]
    assert_contains "$output" "Usage: vhosty proxy <name> <port>"
  done
}

@test "proxy: Caddy's own ports are refused" {
  for own in 48443 48080; do
    run linux main proxy loop "$own"
    [ "$status" -ne 0 ]
    assert_contains "$output" "Caddy's own"
  done
  [ ! -d "$VHOSTY_DIR/proxies" ]
}

@test "proxy: 443 is someone else's, unless Caddy is on it" {
  run linux main proxy nginx 443
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  rm "$VHOSTY_DIR/proxies/nginx.conf"
  touch "$VHOSTY_DIR/serve-fallback"
  run linux proxy_port_is_caddy 443
  [ "$status" -eq 0 ]
  run linux proxy_port_is_caddy 8080
  [ "$status" -ne 0 ]
}

# --- Names that are already sites ---------------------------------------------

@test "proxy: a parked PHP site's name is refused" {
  php_site escrow
  run linux main proxy escrow 3001
  [ "$status" -ne 0 ]
  assert_contains "$output" "already a site (parked in $PARKED)"
  [ ! -f "$VHOSTY_DIR/proxies/escrow.conf" ]
}

@test "proxy: a parked static site's name is refused" {
  static_site hello
  run linux main proxy hello 3001
  [ "$status" -ne 0 ]
  assert_contains "$output" "already a site"
}

@test "proxy: a Vite app can take its own folder's name" {
  mkdir -p "$PARKED/shop"
  echo '<script type=module src=/src/main.tsx></script>' >"$PARKED/shop/index.html"
  echo '{}' >"$PARKED/shop/package.json"
  run linux main proxy shop 5173
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  run linux proxy_checks
  refute_contains "$output" "hides a site"
}

@test "proxy: a site in a second parked folder is seen" {
  mkdir -p "$HOME/Other/shop" "$PARKED/shop"
  echo hi >"$HOME/Other/shop/index.html"
  write_config "VHOSTY_PARKED=\"$PARKED:$HOME/Other\""
  run linux main proxy shop 3001
  [ "$status" -ne 0 ]
  assert_contains "$output" "already a site (parked in $HOME/Other)"
}

@test "proxy: an existing proxy can be moved after its folder becomes a site" {
  mkdir -p "$PARKED/shop"
  linux main proxy shop 3000
  echo hi >"$PARKED/shop/index.html"
  run linux main proxy shop 3001
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  grep -q '^PROXY_PORT=3001$' "$VHOSTY_DIR/proxies/shop.conf"
}

@test "proxy: a broken one can be repaired, as doctor says, whatever its folder holds" {
  static_site shop
  proxy_conf shop abc
  run linux main proxy shop 3001
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  grep -q '^PROXY_PORT=3001$' "$VHOSTY_DIR/proxies/shop.conf"
}

@test "proxy: says the tailnet can reach it" {
  run linux main proxy db 2375
  assert_contains "$output" "every device on your tailnet can now reach it"
}

@test "octane on: a proxy's name is refused, and nothing's written" {
  php_site app
  mkdir -p "$PARKED/app/vendor/laravel/octane"
  echo '{}' >"$PARKED/app/vendor/laravel/octane/composer.json"
  proxy_conf app 3001
  run linux main octane on app
  [ "$status" -ne 0 ]
  assert_contains "$output" "'app' is a proxy"
  [ ! -f "$VHOSTY_DIR/sites/app.conf" ]
}

@test "ini set --site: a proxy's name is refused, and nothing's written" {
  mkdir -p "$PARKED/shop"
  proxy_conf shop 3001
  run linux main ini set memory_limit 1G --site shop
  [ "$status" -ne 0 ]
  assert_contains "$output" "'shop' is a proxy"
  [ ! -f "$VHOSTY_DIR/sites/shop.conf" ]
}

@test "a listener another user owns isn't called Caddy" {
  proxy_conf grafana 3001
  stub ss "echo 'LISTEN 0 0 127.0.0.1:3001 0.0.0.0:*'"
  mkdir -p "$XDG_CONFIG_HOME/systemd/user"
  touch "$XDG_CONFIG_HOME/systemd/user/vhosty-caddy.service"
  stub systemctl 'exit 0'
  run linux proxy_checks
  assert_contains "$output" "(another user's process)"
  refute_contains "$output" "(caddy)"
}

@test "a proxy with a bad port isn't offered on the no-site page" {
  proxy_conf broken abc
  proxy_conf fine 3001
  vh write_configs
  grep -q 'vhosty_sites.*fine' "$VHOSTY_DIR/Caddyfile"
  run grep -c 'vhosty_sites.*broken' "$VHOSTY_DIR/Caddyfile"
  [ "$output" = 0 ]
}

@test "proxy: a parked folder with capitals is the same name" {
  static_site MyApp
  run linux main proxy myapp 3001
  [ "$status" -ne 0 ]
  assert_contains "$output" "already a site"
}

@test "proxy: a linked site's name is refused" {
  mkdir -p "$HOME/elsewhere/app"
  site_conf app "SITE_PATH=$HOME/elsewhere/app
SITE_LINKED=yes"
  run linux main proxy app 3001
  [ "$status" -ne 0 ]
  assert_contains "$output" "already a site (linked to $HOME/elsewhere/app)"
}

@test "proxy: an Octane site's name is refused" {
  php_site escrow
  site_conf escrow "SITE_OCTANE=21000"
  run linux main proxy escrow 3001
  [ "$status" -ne 0 ]
  assert_contains "$output" "already a site (on Octane, port 21000)"
}

@test "proxy: a name with leftover settings is refused, and says about prune" {
  site_conf gone "SITE_PATH=$PARKED/gone
SITE_PHP=8.4"
  run linux main proxy gone 3001
  [ "$status" -ne 0 ]
  assert_contains "$output" "vhosty prune"
}

@test "proxy: a parked folder with nothing to serve doesn't count" {
  mkdir -p "$PARKED/shop/src"
  echo '{}' >"$PARKED/shop/package.json"
  run linux main proxy shop 3001
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  assert_contains "$(cat "$VHOSTY_DIR/Caddyfile")" "@proxy_shop host"
}

@test "proxy: with PHP off, public/index.php doesn't make a site" {
  php_site escrow
  write_config 'VHOSTY_PHP="off"'
  sed -i.bak '/^VHOSTY_PHP="on"/d' "$VHOSTY_DIR/config"
  run linux main proxy escrow 3001
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
}

@test "link: a proxy's name is refused" {
  linux main proxy app 3001
  mkdir -p "$HOME/elsewhere/app"
  run linux main link "$HOME/elsewhere/app" --name app
  [ "$status" -ne 0 ]
  assert_contains "$output" "'app' is a proxy"
  [ ! -f "$VHOSTY_DIR/sites/app.conf" ]
}

@test "a proxy keeps its name over a folder parked later, and says so" {
  linux main proxy hello 3001
  linux main proxy other 3002
  static_site hello
  # A folder with capitals gets a rule of its own: the proxy's still comes first
  static_site Other
  linux main rebuild
  first="$(grep -n '@proxy_other host' "$VHOSTY_DIR/Caddyfile" | cut -d: -f1)"
  second="$(grep -n '@site_other host' "$VHOSTY_DIR/Caddyfile" | cut -d: -f1)"
  [ "$first" -lt "$second" ]
  run linux main sites
  assert_contains "$output" "hello (not served: https://hello.test.example is a proxy)"
  run linux proxy_checks
  assert_contains "$output" "proxy hello hides a site of the same name (parked in $PARKED)"
}

# --- vhosty unproxy, proxies ---------------------------------------------------

@test "unproxy: removes the file and the route" {
  linux main proxy grafana 3001
  run linux main unproxy grafana
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [ ! -f "$VHOSTY_DIR/proxies/grafana.conf" ]
  refute_contains "$(cat "$VHOSTY_DIR/Caddyfile")" "@proxy_grafana"
}

@test "unproxy: says when a hidden site comes back" {
  linux main proxy hello 3001
  static_site hello
  run linux main unproxy hello
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  assert_contains "$output" "goes back to the site it was hiding"
}

@test "unproxy: what isn't a proxy says so, and needs a name" {
  run linux main unproxy nope
  [ "$status" -ne 0 ]
  assert_contains "$output" "'nope' isn't a proxy"
  run linux main unproxy
  [ "$status" -ne 0 ]
  assert_contains "$output" "Usage: vhosty unproxy <name>"
}

@test "unproxy: a name can't reach outside the proxies folder" {
  site_conf keep "SITE_PHP=8.4"
  mkdir -p "$VHOSTY_DIR/proxies"
  run linux main unproxy ../sites/keep
  [ "$status" -ne 0 ]
  [ -f "$VHOSTY_DIR/sites/keep.conf" ]
}

@test "proxies: lists them, and which have nothing listening" {
  proxy_conf grafana 3001
  proxy_conf shop 3002
  listening 3001
  run linux main proxies
  [ "$status" -eq 0 ]
  assert_contains "${lines[0]}" "https://grafana.test.example  → localhost:3001"
  refute_contains "${lines[0]}" "nothing listening"
  assert_contains "${lines[1]}" "https://shop.test.example  → localhost:3002"
  assert_contains "${lines[1]}" "nothing listening"
}

@test "proxies: with none, says how" {
  run linux main proxies
  [ "$status" -eq 0 ]
  assert_contains "$output" "vhosty proxy <name> <port>"
}

@test "mac: the port's owner comes from lsof" {
  proxy_conf grafana 3001
  stub lsof 'echo "COMMAND PID USER"; echo "node 1 me"'
  run mac proxy_checks
  assert_contains "$output" "proxy grafana → localhost:3001 (node)"
}

# --- The other commands -------------------------------------------------------

@test "sites: lists proxies" {
  php_site escrow
  proxy_conf grafana 3001
  run linux main sites
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  assert_contains "$output" "Proxies"
  assert_contains "$output" "https://grafana.test.example  → localhost:3001"
  assert_contains "$output" "https://escrow.test.example"
}

@test "sites: proxies alone are enough, with nothing parked" {
  write_config 'VHOSTY_PARKED=""'
  sed -i.bak "\\#^VHOSTY_PARKED=\"$PARKED\"#d" "$VHOSTY_DIR/config"
  run linux main sites
  [ "$status" -ne 0 ]
  assert_contains "$output" "No sites"
  proxy_conf grafana 3001
  run linux main sites
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  assert_contains "$output" "https://grafana.test.example"
}

@test "open and url work for a proxy" {
  proxy_conf grafana 3001
  stub pbcopy 'cat >/dev/null'
  run linux main url grafana
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [ "${lines[0]}" = "https://grafana.test.example" ]
  stub xdg-open 'echo "$1" >"$HOME/opened"'
  export DISPLAY=:0
  run linux main open grafana
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  assert_contains "$output" "opened https://grafana.test.example"
  # xdg-open runs in the background
  for _ in $(seq 1 50); do [ -s "$HOME/opened" ] && break; sleep 0.1; done
  [ "$(cat "$HOME/opened")" = "https://grafana.test.example" ]
}

@test "site: shows a proxy's port, and what's listening" {
  proxy_conf grafana 3001
  listening 3001
  run linux main site grafana
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  assert_contains "$output" "https://grafana.test.example"
  assert_contains "$output" "localhost:3001"
  assert_contains "$output" "node"
  assert_contains "$output" "$VHOSTY_DIR/proxies/grafana.conf"
  refute_contains "$output" "Folder"
  nothing_listening
  run linux main site grafana
  assert_contains "$output" "nothing"
}

@test "a proxy isn't a site, to anything that walks them" {
  proxy_conf grafana 3001
  [ -z "$(vh site_names)" ]
  [ -z "$(vh stale_sites)" ]
  [ -z "$(vh octane_sites)" ]
  [ -z "$(vh all_php_sites)" ]
  [ -z "$(vh case_sites)" ]
  [ "$(vh php_versions_in_use)" = 8.4 ]
  [ "$(vh svc_all | tr '\n' ' ')" = "php-8.4 caddy " ]
  run vh site_from_dir "$HOME"
  [ "$status" -ne 0 ]
  vh write_configs
  assert_contains "$(cat "$VHOSTY_DIR/Caddyfile")" "@proxy_grafana"
  refute_contains "$(cat "$VHOSTY_DIR/Caddyfile")" "Site: grafana"
}

@test "prune leaves proxies alone, and says there's nothing to do" {
  proxy_conf grafana 3001
  run linux main prune --yes
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  assert_contains "$output" "nothing to prune"
  [ -f "$VHOSTY_DIR/proxies/grafana.conf" ]
}

@test "prune removes a stale site, and leaves a proxy" {
  proxy_conf grafana 3001
  site_conf gone "SITE_PATH=$PARKED/gone
SITE_PHP=8.4"
  run linux main prune --yes --no-rebuild
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [ ! -f "$VHOSTY_DIR/sites/gone.conf" ]
  [ -f "$VHOSTY_DIR/proxies/grafana.conf" ]
}

@test "the php shim has no branch for a proxy" {
  php_site escrow
  site_conf escrow "SITE_PHP=8.4"
  proxy_conf grafana 3001
  vh write_configs
  refute_contains "$(cat "$VHOSTY_DIR/bin/php")" "grafana"
  assert_contains "$(cat "$VHOSTY_DIR/bin/php")" "escrow"
}

@test "Octane doesn't pick a proxy's port" {
  proxy_conf grafana 21000
  [ "$(linux octane_free_port)" = 21001 ]
}

@test "a proxy added by hand counts as drift" {
  vh write_configs
  vh config_in_sync
  proxy_conf grafana 3001
  run vh config_in_sync
  [ "$status" -ne 0 ]
  vh write_configs
  vh config_in_sync
}

# --- A hand-edited file -------------------------------------------------------

@test "a port that isn't one never reaches the Caddyfile, and isn't run" {
  proxy_conf grafana abc
  mkdir -p "$VHOSTY_DIR/proxies"
  printf 'PROXY_PORT=$(touch %s/ran)\n' "$HOME" >"$VHOSTY_DIR/proxies/evil.conf"
  vh write_configs
  [ ! -e "$HOME/ran" ]
  caddyfile="$(cat "$VHOSTY_DIR/Caddyfile")"
  assert_contains "$caddyfile" "# Proxy: grafana (skipped: no valid port in its file)"
  refute_contains "$caddyfile" "@proxy_grafana"
  refute_contains "$caddyfile" "touch"
  run linux main proxies
  assert_contains "$output" "no valid port"
}

@test "a file whose name isn't a proxy name is ignored" {
  mkdir -p "$VHOSTY_DIR/proxies"
  for n in 3000 Bad_Name 'with space'; do printf 'PROXY_PORT=3001\n' >"$VHOSTY_DIR/proxies/$n.conf"; done
  [ -z "$(vh proxy_names)" ]
  vh write_configs
  refute_contains "$(cat "$VHOSTY_DIR/Caddyfile")" "@proxy_"
}

# --- doctor and status --------------------------------------------------------

# What doctor_checks needs that a scratch home doesn't have
doctor_stubs() {
  export VHOSTY_UPDATE_CHECK=0
  stub curl 'printf 000'
  stub dig 'echo 100.64.0.7'
  stub loginctl 'echo yes'
  stub systemctl 'echo inactive'
  stub tailscale 'case "$1" in ip) echo 100.64.0.7 ;; esac'
}

@test "doctor: nothing listening is a warning, not a failure" {
  proxy_conf grafana 3001
  cat >"$HOME/run.sh" <<'SH'
source "$VHOSTY_SRC"; PLATFORM=linux; load_config
proxy_checks
echo "FAILED=$FAILED"
SH
  run env VHOSTY_SRC="$ROOT/bin/vhosty" bash "$HOME/run.sh"
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  assert_contains "$output" "proxy grafana: nothing is listening on port 3001"
  assert_contains "$output" "FAILED=0"
}

@test "doctor: something listening is fine" {
  proxy_conf grafana 3001
  listening 3001
  run linux proxy_checks
  assert_contains "$output" "proxy grafana → localhost:3001 (node)"
  refute_contains "$output" "nothing is listening"
}

@test "doctor: a file with no valid port is a failure" {
  proxy_conf grafana abc
  cat >"$HOME/run.sh" <<'SH'
source "$VHOSTY_SRC"; PLATFORM=linux; load_config
proxy_checks
echo "FAILED=$FAILED"
SH
  run env VHOSTY_SRC="$ROOT/bin/vhosty" bash "$HOME/run.sh"
  assert_contains "$output" "no valid port"
  assert_contains "$output" "FAILED=1"
}

@test "doctor: has a Proxies section, only when there are proxies" {
  doctor_stubs
  run linux doctor_checks
  refute_contains "$output" "Proxies"
  proxy_conf grafana 3001
  run linux doctor_checks
  assert_contains "$output" "Proxies"
  assert_contains "$output" "proxy grafana: nothing is listening on port 3001"
  # Its folder check is for sites: a proxy doesn't have one to lose
  refute_contains "$output" "site grafana"
}

@test "status: shows what's on a proxy's port" {
  doctor_stubs
  proxy_conf grafana 3001
  listening 3001
  run linux cmd_status
  assert_contains "$output" "proxy grafana → localhost:3001 (node)"
}

# --- Herd ---------------------------------------------------------------------

@test "with Herd, the commands point at the port route" {
  write_config 'VHOSTY_BACKEND="herd"'
  for args in "proxy app 3001" "unproxy app" "proxies"; do
    # shellcheck disable=SC2086
    run vh main $args
    [ "$status" -ne 0 ]
    assert_contains "$output" "https://<port>.<domain>"
  done
  [ ! -d "$VHOSTY_DIR/proxies" ]
}

@test "with Herd, a proxy from before isn't routed or checked" {
  proxy_conf grafana 3001
  write_config 'VHOSTY_BACKEND="herd"'
  vh write_configs
  refute_contains "$(cat "$VHOSTY_DIR/Caddyfile")" "@proxy_"
  run linux proxy_checks
  [ -z "$output" ]
}

# --- Through a real Caddy -----------------------------------------------------

# A stand-in for the app, on 127.0.0.1 or (start_app ::1) only on ::1. Answers with
# the request's headers, /down with its own 503, /events with a stream that stays
# open, and a websocket upgrade with a greeting, then echoes one message.
start_app() {
  mkdir -p "$HOME/app"
  cat >"$HOME/app/server.py" <<'PY'
import base64, hashlib, http.server, socket, struct, sys, time

def frame(text):
    data = text.encode()
    return bytes([0x81, len(data)]) + data

class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def do_GET(self):
        if self.headers.get("Upgrade", "").lower() == "websocket":
            return self.websocket()
        if self.path == "/events":
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.end_headers()
            self.wfile.write(b"data: first\n\n")
            self.wfile.flush()
            time.sleep(10)
            self.close_connection = True
            return
        code, body = 200, "host=%s xfh=%s xfp=%s xff=%s\n" % (self.headers.get("Host"), self.headers.get("X-Forwarded-Host"), self.headers.get("X-Forwarded-Proto"), self.headers.get("X-Forwarded-For"))
        body += "".join("%s: %s\n" % kv for kv in self.headers.items())
        if self.path == "/down":
            code, body = 503, "the app's own 503\n"
        self.send_response(code)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body.encode())
    def websocket(self):
        key = self.headers["Sec-WebSocket-Key"] + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        accept = base64.b64encode(hashlib.sha1(key.encode()).digest()).decode()
        self.send_response(101)
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", accept)
        self.end_headers()
        self.wfile.write(frame("hello from the app"))
        self.wfile.flush()
        head = self.rfile.read(2)
        n = head[1] & 0x7f
        mask = self.rfile.read(4)
        data = bytes(b ^ mask[i % 4] for i, b in enumerate(self.rfile.read(n)))
        self.wfile.write(frame("echo: " + data.decode()))
        self.wfile.flush()
        self.close_connection = True
    def log_message(self, *a): pass

class S(http.server.ThreadingHTTPServer):
    address_family = socket.AF_INET6 if ":" in sys.argv[1] else socket.AF_INET
    daemon_threads = True
S((sys.argv[1], int(sys.argv[2])), H).serve_forever()
PY
  python3 -I "$HOME/app/server.py" "${1:-127.0.0.1}" "$APP_PORT" >"$HOME/app/log" 2>&1 &
  APP_PID=$!
  local host="${1:-127.0.0.1}"
  case "$host" in *:*) host="[$host]" ;; esac
  for _ in $(seq 1 50); do
    curl -s -o /dev/null "http://$host:$APP_PORT/" && return 0
    sleep 0.1
  done
  cat "$HOME/app/log" >&2
  return 1
}

# A websocket client on a bare socket, through Caddy, sending the Accept-Encoding
# a browser sends on the upgrade: Caddy's encode is in front of everything
ws_client() {
  cat >"$HOME/ws.py" <<'PY'
import base64, os, socket, sys
s = socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=5)
s.sendall(("GET / HTTP/1.1\r\nHost: %s\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
           "Sec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n"
           "Accept-Encoding: zstd, gzip, deflate, br\r\n\r\n" % (sys.argv[2], base64.b64encode(os.urandom(16)).decode())).encode())
f = s.makefile("rb")
print(f.readline().decode().strip())
while f.readline().strip(): pass
def read_frame():
    head = f.read(2)
    return f.read(head[1] & 0x7f).decode()
print(read_frame())
mask = os.urandom(4)
msg = b"ping"
s.sendall(bytes([0x81, 0x80 | len(msg)]) + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(msg)))
print(read_frame())
PY
  python3 -I "$HOME/ws.py" "$PORT" "$1"
}

# The generated config over plain HTTP on a high port, as in octane.bats
start_caddy() {
  vh write_configs
  sed -e '/^\tadmin /d' -e '/^\thttps\{0,1\}_port /d' -e '/^\tauto_https /d' -e '/^http:\/\//,/^}/d' -e "s/^\tdefault_bind .*/\tadmin off\n\tauto_https off\n\tdefault_bind 127.0.0.1/" \
      -e "s/^\*\.test\.example {/http:\/\/*.test.example:$PORT {/" \
      -e '/^\ttls {/,/^\t}/d' "$VHOSTY_DIR/Caddyfile" >"$HOME/test.Caddyfile"
  "$CADDY" run --config "$HOME/test.Caddyfile" --adapter caddyfile >"$HOME/caddy.log" 2>&1 &
  CADDY_PID=$!
  for _ in $(seq 1 50); do
    curl -s -o /dev/null "http://127.0.0.1:$PORT/" -H "Host: 1.test.example" && return 0
    sleep 0.1
  done
  cat "$HOME/caddy.log" >&2
  return 1
}

need_caddy() { [ -x "$CADDY" ] || skip "no Caddy with the Cloudflare plugin (set VHOSTY_TEST_CADDY)"; }
need_python() { command -v python3 >/dev/null || skip "no python3 for the fake app"; }

get() { curl -s -w '\n%{http_code}' -H "Host: $1.test.example" "http://127.0.0.1:$PORT${2:-/}"; }

@test "the generated Caddyfile is one Caddy accepts" {
  need_caddy
  proxy_conf grafana 3001
  proxy_conf my-app 3002
  proxy_conf broken abc
  vh write_configs
  CF_API_TOKEN=0123456789abcdef0123456789abcdef01234567 run "$CADDY" validate --config "$VHOSTY_DIR/Caddyfile" --adapter caddyfile
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
}

@test "a request reaches the app, with the real host and forwarded headers" {
  need_caddy; need_python
  proxy_conf grafana "$APP_PORT"
  start_app
  start_caddy
  run get grafana
  [ "$(echo "$output" | tail -1)" = 200 ]
  assert_contains "$output" "host=grafana.test.example"
  assert_contains "$output" "xfh=grafana.test.example"
  assert_contains "$output" "xfp=http "
  assert_contains "$output" "xff=127.0.0.1"
}

@test "what a client claims in forwarding and identity headers doesn't reach the app" {
  need_caddy; need_python
  proxy_conf grafana "$APP_PORT"
  start_app
  start_caddy
  run curl -s -H "Host: grafana.test.example" -H 'X-Forwarded-For: 6.6.6.6' -H 'X-Forwarded-Proto: ftp' \
    -H 'X-Forwarded-Host: evil.example' -H 'X-Real-IP: 9.9.9.9' -H 'Forwarded: for=8.8.8.8' \
    -H 'Tailscale-User-Login: admin@corp' -H 'X-Webauth-User: admin' "http://127.0.0.1:$PORT/"
  assert_contains "$output" "host=grafana.test.example"
  assert_contains "$output" "xfp=http "
  assert_contains "$output" "xff=127.0.0.1"
  refute_contains "$output" "6.6.6.6"
  refute_contains "$output" "ftp"
  refute_contains "$output" "evil.example"
  refute_contains "$output" "9.9.9.9"
  refute_contains "$output" "8.8.8.8"
  refute_contains "$output" "admin"
}

@test "a proxy from before wins over an Octane site made by hand, through Caddy" {
  need_caddy; need_python
  php_site hello
  site_conf hello "SITE_OCTANE=18999"
  proxy_conf hello "$APP_PORT"
  start_app
  start_caddy
  run get hello
  [ "$(echo "$output" | tail -1)" = 200 ]
  assert_contains "$output" "host=hello.test.example"
}

@test "an app listening only on ::1 is reached, where localhost includes it" {
  need_caddy; need_python
  python3 -I -c 'import socket, sys; sys.exit(0 if any(a[4][0] == "::1" for a in socket.getaddrinfo("localhost", 80)) else 1)' \
    || skip "localhost is only 127.0.0.1 in this machine's /etc/hosts"
  proxy_conf grafana "$APP_PORT"
  start_app ::1 || skip "couldn't listen on ::1"
  start_caddy
  run get grafana
  [ "$(echo "$output" | tail -1)" = 200 ]
  assert_contains "$output" "host=grafana.test.example"
}

@test "a websocket works in both directions, past the compression" {
  need_caddy; need_python
  proxy_conf grafana "$APP_PORT"
  start_app
  start_caddy
  run ws_client grafana.test.example
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  assert_contains "${lines[0]}" "101"
  [ "${lines[1]}" = "hello from the app" ]
  [ "${lines[2]}" = "echo: ping" ]
}

@test "server-sent events arrive as they're sent, past the compression" {
  need_caddy; need_python
  proxy_conf grafana "$APP_PORT"
  start_app
  start_caddy
  # The app holds the stream open for longer than this, so the event had to be flushed
  run curl -s -N --compressed --max-time 2 -H "Host: grafana.test.example" "http://127.0.0.1:$PORT/events"
  [ "$status" -eq 28 ] || { echo "$status: $output" >&2; false; }
  assert_contains "$output" "data: first"
}

@test "nothing answering gets vhosty's page, which reloads itself" {
  need_caddy
  proxy_conf grafana "$APP_PORT"
  start_caddy
  run get grafana
  [ "$(echo "$output" | tail -1)" = 502 ]
  assert_contains "$output" "Nothing is answering on port $APP_PORT"
  assert_contains "$output" "<code>localhost:$APP_PORT</code>"
  assert_contains "$output" "vhosty proxy grafana &lt;port&gt;"
  assert_contains "$output" '<meta http-equiv="refresh" content="2">'
}

@test "the app's own errors pass through" {
  need_caddy; need_python
  proxy_conf grafana "$APP_PORT"
  start_app
  start_caddy
  run get grafana /down
  [ "$(echo "$output" | tail -1)" = 503 ]
  assert_contains "$output" "the app's own 503"
  refute_contains "$output" "vhosty"
}

@test "the no-site page lists proxies" {
  need_caddy
  proxy_conf grafana "$APP_PORT"
  start_caddy
  run get nosuch
  [ "$(echo "$output" | tail -1)" = 404 ]
  assert_contains "$output" "https://grafana.test.example/"
}

@test "a proxy wins over a folder of the same name, and the port route still works" {
  need_caddy; need_python
  static_site hello
  proxy_conf hello "$APP_PORT"
  start_app
  start_caddy
  run get hello
  assert_contains "$output" "host=hello.test.example"
  refute_contains "$output" "<h1>hi</h1>"
  run get 5998
  [ "$(echo "$output" | tail -1)" = 502 ]
  assert_contains "$output" "Nothing is running on port 5998"
}

@test "other sites aren't affected by a proxy" {
  need_caddy
  static_site hello
  proxy_conf grafana "$APP_PORT"
  start_caddy
  run get hello
  [ "$(echo "$output" | tail -1)" = 200 ]
  assert_contains "$output" "<h1>hi</h1>"
}

@test "after unproxy, the name is gone" {
  need_caddy
  proxy_conf grafana "$APP_PORT"
  linux main unproxy grafana
  start_caddy
  run get grafana
  [ "$(echo "$output" | tail -1)" = 404 ]
}
