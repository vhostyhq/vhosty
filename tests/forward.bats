#!/usr/bin/env bats
# VHOSTY_FORWARD: Caddy forwards <name>.domain to another web server on this
# machine as <name>.<tld>. Herd is the preset most tested here: a fake Herd
# folder stands in for its config, and small Python servers for its nginx.

load helpers

HTTP_PORT=18081
HTTPS_PORT=18444
PORT=18445

# Found before vhosty_setup points HOME at a scratch folder
CADDY="${VHOSTY_TEST_CADDY:-$HOME/.vhosty/bin/caddy}"

setup() {
  vhosty_setup
  export VHOSTY_HERD_DIR="$HOME/Library/Application Support/Herd"
  VALET="$VHOSTY_HERD_DIR/config/valet"
  mkdir -p "$VALET/Sites" "$VALET/Certificates" "$HOME/Herd"
  herd_config test
  forward_config herd
}

teardown() {
  local p
  for p in ${CADDY_PID:-} ${HTTP_PID:-} ${HTTPS_PID:-}; do kill "$p" 2>/dev/null || true; done
}

# forward_config TARGET [extra lines]: forwarding to the fake servers
forward_config() {
  write_config "VHOSTY_FORWARD=\"$1\"
VHOSTY_FORWARD_HTTP=\"127.0.0.1:$HTTP_PORT\"
VHOSTY_FORWARD_HTTPS=\"127.0.0.1:$HTTPS_PORT\"
${2:-}"
}

# herd_config TLD: Herd's config.json, parking ~/Herd
herd_config() {
  printf '{\n    "tld": "%s",\n    "paths": [\n        "%s"\n    ]\n}\n' "$1" "$HOME/Herd" >"$VALET/config.json"
}

herd_site() { mkdir -p "$HOME/Herd/$1"; }
secure() { touch "$VALET/Certificates/$1.test.crt"; }

@test "forwarding, Caddy listens on localhost's ports 48443 and 48080, not 80 or 443" {
  vh write_configs
  caddyfile="$(cat "$VHOSTY_DIR/Caddyfile")"
  run grep -E '^\s*default_bind' "$VHOSTY_DIR/Caddyfile"
  [ "$output" = "$(printf '\tdefault_bind 127.0.0.1')" ]
  assert_contains "$caddyfile" "https_port 48443"
  assert_contains "$caddyfile" "http_port 48080"
  assert_contains "$caddyfile" "auto_https disable_redirects"
}

@test "forwarded to Herd, names go to it as <name>.test, and nothing is served by vhosty" {
  php_site escrow   # a folder in vhosty's parked dir: ignored with Herd
  vh write_configs
  caddyfile="$(cat "$VHOSTY_DIR/Caddyfile")"
  assert_contains "$caddyfile" "header_up Host {labels.2}.test"
  assert_contains "$caddyfile" "reverse_proxy http://127.0.0.1:$HTTP_PORT"
  assert_contains "$caddyfile" "try_files {labels.2}.test.crt"
  assert_contains "$caddyfile" "vhosty_kind forward"
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

@test "forwarding, the Caddyfile doesn't depend on the Tailscale address" {
  vh write_configs
  before="$(cat "$VHOSTY_DIR/Caddyfile")"
  stub tailscale 'exit 1'
  vh write_configs
  [ "$(cat "$VHOSTY_DIR/Caddyfile")" = "$before" ]
}

@test "forwarding, there's no PHP-FPM and no php shim" {
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
  run vh forward_sites
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
  PATH="$HOME/nojq" run vh valet_paths
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

@test "commands for vhosty's own sites say Herd serves them" {
  run vh main park
  [ "$status" -ne 0 ]
  assert_contains "$output" "Herd serves the sites on this machine (VHOSTY_FORWARD=herd)"
  assert_contains "$output" "(herd)"
  run vh main isolate 8.4
  assert_contains "$output" "Herd serves the sites"
  run vh main ini set memory_limit 1G
  assert_contains "$output" "Herd serves the sites"
  run vh main edit php
  assert_contains "$output" "Herd serves the sites"
}

@test "proxies work while forwarding, and come before Herd's sites" {
  run vh main proxy vite 5173
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  caddyfile="$(cat "$VHOSTY_DIR/Caddyfile")"
  proxy="$(printf '%s\n' "$caddyfile" | grep -n '@proxy_vite host' | cut -d: -f1)"
  forward="$(printf '%s\n' "$caddyfile" | grep -n '# Forward:' | cut -d: -f1)"
  [ "$proxy" -lt "$forward" ]
}

@test "a proxy can't take the name of a Herd site, and doctor says when one hides it" {
  herd_site escrow
  run vh main proxy escrow 3000
  [ "$status" -ne 0 ]
  assert_contains "$output" "'escrow' is already a site (on Herd, parked in ~/Herd/escrow)"
  mkdir -p "$VHOSTY_DIR/proxies"
  printf 'PROXY_PORT=3000\n' >"$VHOSTY_DIR/proxies/escrow.conf"
  run vh proxy_checks
  assert_contains "$output" "proxy escrow hides a site of the same name (on Herd"
  run vh cmd_sites
  assert_contains "$output" "escrow (not reached: https://escrow.test.example is a proxy)"
}

@test "the old VHOSTY_BACKEND=herd is read as VHOSTY_FORWARD=herd, and rebuild writes it so" {
  write_config "VHOSTY_BACKEND=\"herd\""
  run vh fallback_mode
  [ "$output" = forward ]
  run vh main rebuild
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  assert_contains "$output" "VHOSTY_BACKEND=herd is now VHOSTY_FORWARD=herd"
  run cat "$VHOSTY_DIR/config"
  assert_contains "$output" "VHOSTY_FORWARD=herd"
  assert_contains "$output" "VHOSTY_SITES=off"
  refute_contains "$output" "VHOSTY_BACKEND"
}

@test "a TLD forwards to any server, over http unless told" {
  forward_config test
  vh write_configs
  caddyfile="$(cat "$VHOSTY_DIR/Caddyfile")"
  assert_contains "$caddyfile" "header_up Host {labels.2}.test"
  assert_contains "$caddyfile" "reverse_proxy http://127.0.0.1:$HTTP_PORT"
  refute_contains "$caddyfile" "forward_secured"
  refute_contains "$caddyfile" "reverse_proxy https://"
  assert_contains "$caddyfile" 'vhosty_forward_name "the web server on this machine"'
}

@test "VHOSTY_FORWARD_TLS=always sends every name over https" {
  forward_config test 'VHOSTY_FORWARD_TLS="always"'
  vh write_configs
  caddyfile="$(cat "$VHOSTY_DIR/Caddyfile")"
  assert_contains "$caddyfile" "reverse_proxy https://127.0.0.1:$HTTPS_PORT"
  refute_contains "$caddyfile" "reverse_proxy http://"
}

@test "VHOSTY_FORWARD_TLS=auto needs a certificate folder, and uses the one given" {
  forward_config test 'VHOSTY_FORWARD_TLS="auto"'
  run vh write_configs
  [ "$status" -ne 0 ]
  assert_contains "$output" "VHOSTY_FORWARD_TLS=auto needs VHOSTY_FORWARD_CERTS"
  forward_config dev "VHOSTY_FORWARD_CERTS=\"~/certs\""
  vh write_configs
  caddyfile="$(cat "$VHOSTY_DIR/Caddyfile")"
  assert_contains "$caddyfile" "root \"$HOME/certs\""
  assert_contains "$caddyfile" "try_files {labels.2}.dev.crt"
}

@test "forward settings that would break the Caddyfile are refused" {
  for bad in 'VHOSTY_FORWARD="Not A TLD"' 'VHOSTY_FORWARD="test"
VHOSTY_FORWARD_TLD="te st"' 'VHOSTY_FORWARD="test"
VHOSTY_FORWARD_HTTP="127.0.0.1:80 {"' 'VHOSTY_FORWARD="test"
VHOSTY_FORWARD_TLS="sometimes"' 'VHOSTY_FORWARD="test"
VHOSTY_FORWARD_TLS="auto"
VHOSTY_FORWARD_CERTS="/tmp/a\"b"' 'VHOSTY_FORWARD="test"
VHOSTY_FORWARD_HTTP="127.0.0.1:99999"' "VHOSTY_FORWARD=\"test\"
VHOSTY_FORWARD_HTTP=\$'127.0.0.1:80 {\\n127.0.0.1:80'" "VHOSTY_FORWARD=\$'test\\nNot A TLD'"; do
    write_config "$bad"
    run vh write_configs
    [ "$status" -ne 0 ] || { echo "accepted: $bad" >&2; false; }
  done
}

@test "Valet's folder: ~/.config/valet, else ~/.valet; its TLD comes from its config" {
  forward_config valet
  run vh valet_dir
  [ "$output" = "$HOME/.valet" ]
  mkdir -p "$HOME/.config/valet/Certificates"
  printf '{"tld":"localhost","paths":[]}' >"$HOME/.config/valet/config.json"
  run vh valet_dir
  [ "$output" = "$HOME/.config/valet" ]
  vh write_configs
  caddyfile="$(cat "$VHOSTY_DIR/Caddyfile")"
  assert_contains "$caddyfile" "header_up Host {labels.2}.localhost"
  assert_contains "$caddyfile" "root \"$HOME/.config/valet/Certificates\""
}

@test "forwarding, the drift check doesn't look for the Tailscale address" {
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

@test "the forward Caddyfile is valid, in each https mode" {
  [ -x "$CADDY" ] || skip "no Caddy with the Cloudflare plugin (set VHOSTY_TEST_CADDY)"
  for tls in auto always never; do
    forward_config herd "VHOSTY_FORWARD_TLS=\"$tls\""
    vh write_configs
    CF_API_TOKEN=0123456789abcdef0123456789abcdef01234567 run "$CADDY" validate --config "$VHOSTY_DIR/Caddyfile" --adapter caddyfile
    [ "$status" -eq 0 ] || { echo "$tls: $output" >&2; false; }
  done
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

@test "a server not answering gets vhosty's 502 page, naming it" {
  need_caddy
  herd_site escrow
  start_caddy
  run get escrow
  [ "$(echo "$output" | tail -1)" = 502 ]
  assert_contains "$output" "Herd isn't answering"
  assert_contains "$output" "<code>escrow.test</code>"
  assert_contains "$output" "herd restart"
  kill "$CADDY_PID"; wait "$CADDY_PID" 2>/dev/null || true
  forward_config test
  start_caddy
  run get escrow
  assert_contains "$output" "The web server on this machine isn't answering"
  refute_contains "$output" " restart</pre>"
}

@test "forwarding, port sites still go to localhost" {
  need_caddy
  start_herd
  start_caddy
  run get "$HTTP_PORT"
  [ "$(echo "$output" | tail -1)" = 403 ]   # not in VHOSTY_PORTS
  forward_config herd "VHOSTY_PORTS=\"$HTTP_PORT\""
  kill "$CADDY_PID"; wait "$CADDY_PID" 2>/dev/null || true
  start_caddy
  run get "$HTTP_PORT"
  [ "$(echo "$output" | tail -1)" = 200 ]
  assert_contains "$output" "host=$HTTP_PORT.test.example"
}

@test "Lerd: its TLD from config.yaml, its certificates from its data folder" {
  forward_config lerd
  mkdir -p "$XDG_CONFIG_HOME/lerd" "$XDG_DATA_HOME/lerd/certs/sites"
  vh write_configs
  caddyfile="$(cat "$VHOSTY_DIR/Caddyfile")"
  assert_contains "$caddyfile" "header_up Host {labels.2}.test"
  assert_contains "$caddyfile" "root \"$XDG_DATA_HOME/lerd/certs/sites\""
  assert_contains "$caddyfile" "try_files {labels.2}.test.crt"
  printf 'dns:\n  enabled: true\n  tld: "lerd"\nnginx:\n  http_port: 80\n  tld: other\n' >"$XDG_CONFIG_HOME/lerd/config.yaml"
  vh write_configs
  caddyfile="$(cat "$VHOSTY_DIR/Caddyfile")"
  assert_contains "$caddyfile" "header_up Host {labels.2}.lerd"
  assert_contains "$caddyfile" "try_files {labels.2}.lerd.crt"
}
