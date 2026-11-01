#!/usr/bin/env bats
# VHOSTY_BACKEND=herd: Caddy on the Tailscale address forwards <name>.domain to
# Herd's nginx as <name>.test. A fake Herd folder stands in for Herd's config,
# and small Python servers stand in for its nginx.

load helpers

HTTP_PORT=18081
HTTPS_PORT=18444
PORT=18445

# Found before vhosty_setup points HOME at a scratch folder
CADDY="${VHOSTY_TEST_CADDY:-$HOME/.vhosty/bin/caddy}"

setup() {
  vhosty_setup
  export VHOSTY_HERD_DIR="$HOME/Library/Application Support/Herd"
  export VHOSTY_HERD_HTTP="127.0.0.1:$HTTP_PORT" VHOSTY_HERD_HTTPS="127.0.0.1:$HTTPS_PORT"
  VALET="$VHOSTY_HERD_DIR/config/valet"
  mkdir -p "$VALET/Sites" "$VALET/Certificates" "$HOME/Herd"
  herd_config test
  write_config 'VHOSTY_BACKEND="herd"'
}

teardown() {
  local p
  for p in ${CADDY_PID:-} ${HTTP_PID:-} ${HTTPS_PID:-}; do kill "$p" 2>/dev/null || true; done
}

# herd_config TLD: Herd's config.json, parking ~/Herd
herd_config() {
  printf '{\n    "tld": "%s",\n    "paths": [\n        "%s"\n    ]\n}\n' "$1" "$HOME/Herd" >"$VALET/config.json"
}

herd_site() { mkdir -p "$HOME/Herd/$1"; }
secure() { touch "$VALET/Certificates/$1.test.crt"; }

@test "with Herd, Caddy listens on localhost's ports 48443 and 48080, not 80 or 443" {
  vh write_configs
  caddyfile="$(cat "$VHOSTY_DIR/Caddyfile")"
  run grep -E '^\s*default_bind' "$VHOSTY_DIR/Caddyfile"
  [ "$output" = "$(printf '\tdefault_bind 127.0.0.1')" ]
  assert_contains "$caddyfile" "https_port 48443"
  assert_contains "$caddyfile" "http_port 48080"
  assert_contains "$caddyfile" "auto_https disable_redirects"
}

@test "with Herd, sites go to Herd as <name>.test, and nothing is served by vhosty" {
  php_site escrow   # a folder in vhosty's parked dir: ignored with Herd
  vh write_configs
  caddyfile="$(cat "$VHOSTY_DIR/Caddyfile")"
  assert_contains "$caddyfile" "header_up Host {labels.2}.test"
  assert_contains "$caddyfile" "reverse_proxy http://127.0.0.1:$HTTP_PORT"
  assert_contains "$caddyfile" "try_files {labels.2}.test.crt"
  refute_contains "$caddyfile" "php_fastcgi"
  refute_contains "$caddyfile" "vhosty_kind nosite"
  # the port route stays
  assert_contains "$caddyfile" "reverse_proxy localhost:{re.port.1}"
}

@test "Herd's TLD comes from its config" {
  herd_config herd
  vh write_configs
  assert_contains "$(cat "$VHOSTY_DIR/Caddyfile")" "header_up Host {labels.2}.herd"
}

@test "with Herd, the Caddyfile doesn't depend on the Tailscale address" {
  vh write_configs
  before="$(cat "$VHOSTY_DIR/Caddyfile")"
  stub tailscale 'exit 1'
  vh write_configs
  [ "$(cat "$VHOSTY_DIR/Caddyfile")" = "$before" ]
}

@test "with Herd, there's no PHP-FPM and no php shim" {
  run vh svc_all
  [ "$output" = "caddy" ]
  vh write_configs
  [ ! -e "$VHOSTY_DIR/bin/php" ]
}

@test "Herd's sites: links and parked folders, a link winning over a parked folder" {
  herd_site escrow
  herd_site Kudos
  mkdir -p "$HOME/Projects/escrow-v2" "$HOME/Projects/api"
  ln -s "$HOME/Projects/escrow-v2" "$VALET/Sites/escrow"
  ln -s "$HOME/Projects/api" "$VALET/Sites/api"
  run vh herd_sites
  [ "$status" -eq 0 ]
  assert_contains "$output" "escrow|$(cd "$HOME/Projects/escrow-v2" && pwd -P)|linked"
  assert_contains "$output" "api|"
  assert_contains "$output" "kudos|$HOME/Herd/Kudos|parked"
  [ "$(printf '%s\n' "$output" | grep -c '^escrow|')" -eq 1 ]
}

@test "Herd's parked folders are read without jq too" {
  printf '{"tld":"test","paths":["%s","\\/opt\\/sites"],"loopback":"127.0.0.1"}\n' "$HOME/Herd" >"$VALET/config.json"
  # a PATH with the usual tools, but no jq (as on macOS before 15)
  mkdir -p "$HOME/nojq"
  for t in bash env sed tr cat uname id awk grep sort head cut mktemp rm; do
    ln -s "$(command -v "$t")" "$HOME/nojq/$t"
  done
  PATH="$HOME/nojq" run vh herd_paths
  [ "$output" = "$(printf '%s\n/opt/sites' "$HOME/Herd")" ]
}

@test "vhosty url finds the Herd site of the current folder" {
  herd_site escrow
  mkdir -p "$HOME/Herd/escrow/app/Models"
  cd "$HOME/Herd/escrow/app/Models"
  run vh site_url
  [ "$output" = "https://escrow.test.example" ]
}

@test "vhosty sites lists Herd's sites and says which aren't secured" {
  herd_site escrow
  herd_site kudos
  secure escrow
  run vh cmd_sites
  assert_contains "$output" "https://escrow.test.example"
  assert_contains "$output" "(parked)"
  assert_contains "$output" "https://kudos.test.example"
  assert_contains "$output" "(parked, not secured)"
}

@test "commands that are Herd's job say what to use instead" {
  run vh main park
  [ "$status" -ne 0 ]
  assert_contains "$output" "herd park"
  run vh main isolate 8.4
  assert_contains "$output" "herd isolate"
  run vh main ini set memory_limit 1G
  assert_contains "$output" "Herd's PHP settings"
  run vh main edit php
  assert_contains "$output" "Herd's PHP settings"
}

@test "without VHOSTY_BACKEND, nothing changes" {
  write_config
  vh write_configs
  caddyfile="$(cat "$VHOSTY_DIR/Caddyfile")"
  refute_contains "$caddyfile" "Herd"
  assert_contains "$caddyfile" "default_bind 100.64.0.7 127.0.0.1 ::1"
}

@test "with Herd, the drift check doesn't look for the Tailscale address" {
  vh write_configs
  run vh drift_reason
  [ "$output" = "settings changed since the last rebuild" ]
}

# --- Through a real Caddy ----------------------------------------------------

need_caddy() {
  [ -x "$CADDY" ] || skip "no Caddy with the Cloudflare plugin (set VHOSTY_TEST_CADDY)"
  command -v python3 >/dev/null || skip "no python3 for the fake Herd"
}

# Stand-ins for Herd's nginx: they answer with the request's Host and
# X-Forwarded-* headers, and the HTTPS one with the name asked for in TLS (SNI)
start_herd() {
  mkdir -p "$HOME/fake-herd"
  cat >"$HOME/fake-herd/server.py" <<'PY'
import http.server, ssl, sys
port, cert = int(sys.argv[1]), (sys.argv[2] if len(sys.argv) > 2 else None)
sni = {"name": ""}
class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def do_GET(self):
        body = "host=%s xfh=%s xfp=%s sni=%s\n" % (
            self.headers.get("Host"), self.headers.get("X-Forwarded-Host"),
            self.headers.get("X-Forwarded-Proto"), sni["name"])
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body.encode())
    def log_message(self, *a): pass
s = http.server.ThreadingHTTPServer(("127.0.0.1", port), H)
if cert:
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(cert)
    def remember(sock, name, c): sni["name"] = name or ""
    ctx.sni_callback = remember
    s.socket = ctx.wrap_socket(s.socket, server_side=True)
s.serve_forever()
PY
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=herd" \
    -keyout "$HOME/fake-herd/cert.pem" -out "$HOME/fake-herd/cert.pem.crt" >/dev/null 2>&1
  cat "$HOME/fake-herd/cert.pem.crt" >>"$HOME/fake-herd/cert.pem"
  python3 -I "$HOME/fake-herd/server.py" "$HTTP_PORT" >"$HOME/fake-herd/http.log" 2>&1 &
  HTTP_PID=$!
  python3 -I "$HOME/fake-herd/server.py" "$HTTPS_PORT" "$HOME/fake-herd/cert.pem" >"$HOME/fake-herd/https.log" 2>&1 &
  HTTPS_PID=$!
  for _ in $(seq 1 50); do
    curl -s -o /dev/null "http://127.0.0.1:$HTTP_PORT/" && curl -sk -o /dev/null "https://127.0.0.1:$HTTPS_PORT/" && return 0
    sleep 0.1
  done
  cat "$HOME/fake-herd/"*.log >&2
  return 1
}

# The generated config over plain HTTP on a high port, as in caddy.bats
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

get() { curl -s -w '\n%{http_code}' -H "Host: $1.test.example" "http://127.0.0.1:$PORT${2:-/}"; }

@test "the Herd Caddyfile is valid" {
  [ -x "$CADDY" ] || skip "no Caddy with the Cloudflare plugin (set VHOSTY_TEST_CADDY)"
  vh write_configs
  CF_API_TOKEN=0123456789abcdef0123456789abcdef01234567 run "$CADDY" validate --config "$VHOSTY_DIR/Caddyfile" --adapter caddyfile
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
}

@test "an unsecured Herd site is reached over http, as <name>.test, with the real host forwarded" {
  need_caddy
  herd_site escrow
  start_herd
  start_caddy
  run get escrow
  [ "$(echo "$output" | tail -1)" = 200 ]
  assert_contains "$output" "host=escrow.test xfh=escrow.test.example"
  assert_contains "$output" "sni="
  refute_contains "$output" "sni=escrow"
}

@test "a secured Herd site is reached over https, asking for <name>.test" {
  need_caddy
  herd_site escrow
  secure escrow
  start_herd
  start_caddy
  run get escrow
  [ "$(echo "$output" | tail -1)" = 200 ]
  assert_contains "$output" "host=escrow.test xfh=escrow.test.example"
  assert_contains "$output" "sni=escrow.test"
}

@test "Herd not answering gets vhosty's 502 page" {
  need_caddy
  herd_site escrow
  start_caddy
  run get escrow
  [ "$(echo "$output" | tail -1)" = 502 ]
  assert_contains "$output" "Herd isn't answering"
  assert_contains "$output" "<code>escrow.test</code>"
}

@test "with Herd, port sites still go to localhost" {
  need_caddy
  start_herd
  start_caddy
  run get "$HTTP_PORT"
  [ "$(echo "$output" | tail -1)" = 403 ]   # not in VHOSTY_PORTS
  write_config "VHOSTY_BACKEND=\"herd\"
VHOSTY_PORTS=\"$HTTP_PORT\""
  kill "$CADDY_PID"; wait "$CADDY_PID" 2>/dev/null || true
  start_caddy
  run get "$HTTP_PORT"
  [ "$(echo "$output" | tail -1)" = 200 ]
  assert_contains "$output" "host=$HTTP_PORT.test.example"
}
