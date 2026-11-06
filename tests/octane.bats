#!/usr/bin/env bats
# vhosty octane: a site's app runs in a server of its own, on a local port, as a
# service; Caddy passes the site's name to that port. Small Python servers stand
# in for Octane, and a stub php for artisan.

load helpers

OCTANE_PORT=18081
PORT=18446

# Found before vhosty_setup points HOME at a scratch folder
CADDY="${VHOSTY_TEST_CADDY:-$HOME/.vhosty/bin/caddy}"

teardown() {
  local p
  for p in ${CADDY_PID:-} ${OCTANE_PID:-}; do kill "$p" 2>/dev/null || true; done
}

# octane_site NAME [SERVER]: a parked Laravel app with Octane installed, its
# server's binary there, and artisan answered by a stub php that logs its arguments
octane_site() {
  php_site "$1"
  mkdir -p "$PARKED/$1/vendor/laravel/octane"
  echo '{}' >"$PARKED/$1/vendor/laravel/octane/composer.json"
  echo "OCTANE_SERVER=${2:-frankenphp}" >"$PARKED/$1/.env"
  printf '#!/bin/sh\n' >"$PARKED/$1/frankenphp"
  chmod +x "$PARKED/$1/frankenphp"
  mkdir -p "$VHOSTY_DIR/bin"
  printf '#!/usr/bin/env bash\necho "php $* (in $PWD)" >>"%s/php.log"\n' "$HOME" >"$VHOSTY_DIR/bin/php"
  chmod +x "$VHOSTY_DIR/bin/php"
}

@test "a site on Octane goes to its port, and doesn't touch PHP-FPM" {
  php_site escrow
  site_conf escrow "SITE_OCTANE=21000"
  vh write_configs
  caddyfile="$(cat "$VHOSTY_DIR/Caddyfile")"
  assert_contains "$caddyfile" "@site_escrow host escrow.test.example"
  assert_contains "$caddyfile" "reverse_proxy 127.0.0.1:21000"
  assert_contains "$caddyfile" "vars vhosty_kind octane"
  block="$(printf '%s\n' "$caddyfile" | sed -n '/@site_escrow host/,/^	}/p')"
  refute_contains "$block" "php_fastcgi"
}

@test "a site without the setting stays on PHP-FPM" {
  php_site escrow
  site_conf escrow "SITE_PHP=8.4"
  vh write_configs
  refute_contains "$(cat "$VHOSTY_DIR/Caddyfile")" "vhosty_kind octane"
  assert_contains "$(cat "$VHOSTY_DIR/Caddyfile")" "php_fastcgi"
}

@test "the setting alone keeps a site's config file, and removing it removes the file" {
  php_site escrow
  cat >"$HOME/save.sh" <<'SH'
source "$VHOSTY_SRC"; load_config
site_load escrow; SITE_OCTANE=21000; SITE_OCTANE_WORKERS=4; site_save escrow
site_load escrow; echo "$SITE_OCTANE $SITE_OCTANE_WORKERS"
SITE_OCTANE=""; SITE_OCTANE_WORKERS=""; site_save escrow
[ ! -f "$(site_file escrow)" ] && echo gone
SH
  run env VHOSTY_SRC="$ROOT/bin/vhosty" bash "$HOME/save.sh"
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [ "${lines[0]}" = "21000 4" ]
  [ "${lines[1]}" = "gone" ]
}

@test "the services are PHP, then Octane sites, then Caddy" {
  php_site escrow
  php_site other
  site_conf escrow "SITE_OCTANE=21000"
  run vh svc_all
  [ "$(printf '%s\n' "$output" | tr '\n' ' ')" = "php-8.4 octane-escrow caddy " ]
}

@test "a site whose folder is gone has no service" {
  site_conf gone "SITE_PATH=$PARKED/gone
SITE_OCTANE=21000"
  run vh octane_sites
  [ -z "$output" ]
}

@test "with PHP off there are no Octane services" {
  php_site escrow
  site_conf escrow "SITE_OCTANE=21000"
  write_config 'VHOSTY_PHP="off"'
  sed -i.bak '/^VHOSTY_PHP="on"/d' "$VHOSTY_DIR/config"
  run vh octane_sites
  [ -z "$output" ]
}

@test "services can be named by site, or all together" {
  php_site escrow
  php_site other
  site_conf escrow "SITE_OCTANE=21000"
  site_conf other "SITE_OCTANE=21001"
  [ "$(vh svc_resolve octane-escrow)" = "octane-escrow" ]
  [ "$(vh svc_resolve octane | tr '\n' ' ')" = "octane-escrow octane-other " ]
  [ "$(vh svc_log octane-escrow)" = "$VHOSTY_DIR/logs/octane-escrow.log" ]
  [ "$(vh unit_of octane-escrow)" = "vhosty-octane-escrow.service" ]
}

@test "a site that isn't on Octane isn't a service" {
  php_site escrow
  run vh svc_resolve octane-escrow
  [ "$status" -ne 0 ]
  assert_contains "$output" "vhosty octane on escrow"
}

@test "the command binds to localhost, on the site's port, with few workers" {
  octane_site escrow
  site_conf escrow "SITE_OCTANE=21000"
  run vh octane_cmd escrow
  [ "${lines[0]}" = "$VHOSTY_DIR/bin/php" ]
  assert_contains "$output" "octane:start"
  assert_contains "$output" "--host=127.0.0.1"
  assert_contains "$output" "--port=21000"
  assert_contains "$output" "--workers=2"
}

@test "a site can have more workers" {
  octane_site escrow
  site_conf escrow "SITE_OCTANE=21000
SITE_OCTANE_WORKERS=6"
  run vh octane_cmd escrow
  assert_contains "$output" "--workers=6"
  assert_contains "$output" "--task-workers=6"
}

@test "FrankenPHP watches files without Node" {
  octane_site escrow frankenphp
  site_conf escrow "SITE_OCTANE=21000"
  export PATH="$HOME/stubs:/usr/bin:/bin"
  command -v node >/dev/null && skip "node is in /usr/bin here"
  run vh octane_cmd escrow
  assert_contains "$output" "--watch"
}

@test "the other servers only watch with Node and chokidar" {
  octane_site escrow swoole
  site_conf escrow "SITE_OCTANE=21000"
  export PATH="$HOME/stubs:/usr/bin:/bin"
  command -v node >/dev/null && skip "node is in /usr/bin here"
  run vh octane_cmd escrow
  refute_contains "$output" "--watch"
  stub node 'exit 0'
  run vh octane_cmd escrow
  refute_contains "$output" "--watch"
  mkdir -p "$PARKED/escrow/node_modules/chokidar"
  run vh octane_cmd escrow
  assert_contains "$output" "--watch"
}

@test "no named server means Octane's default, RoadRunner" {
  octane_site escrow
  rm "$PARKED/escrow/.env"
  [ "$(vh octane_server "$PARKED/escrow")" = roadrunner ]
  printf 'APP_NAME=x\nOCTANE_SERVER="swoole"\n' >"$PARKED/escrow/.env"
  [ "$(vh octane_server "$PARKED/escrow")" = swoole ]
}

@test "the unit runs in the site's folder, with https links and Node on its PATH" {
  octane_site escrow
  site_conf escrow "SITE_OCTANE=21000"
  stub node 'exit 0'
  mkdir -p "$XDG_CONFIG_HOME/systemd/user"
  linux write_octane_unit escrow
  unit="$(cat "$XDG_CONFIG_HOME/systemd/user/vhosty-octane-escrow.service")"
  assert_contains "$unit" "WorkingDirectory=$PARKED/escrow"
  assert_contains "$unit" "Environment=OCTANE_HTTPS=true"
  assert_contains "$unit" "PATH=$VHOSTY_DIR/bin:$HOME/stubs:"
  assert_contains "$unit" "ExecStart=$VHOSTY_DIR/bin/php artisan octane:start --host=127.0.0.1 --port=21000"
  assert_contains "$unit" "StandardOutput=append:$VHOSTY_DIR/logs/octane-escrow.log"
  # The leading colon keeps PHP's own folder, where its extensions are turned on
  assert_contains "$unit" "PHP_INI_SCAN_DIR=:$VHOSTY_DIR/octane/escrow"
  # systemd sets no PWD, and through a symlink the shim wouldn't find the site's pin
  assert_contains "$unit" "Environment=\"PWD=$PARKED/escrow\""
}

@test "a percent sign in the folder is escaped for systemd" {
  mkdir -p "$HOME/My100%/app/public"
  site_conf app "SITE_PATH=\"$HOME/My100%/app\"
SITE_LINKED=yes
SITE_OCTANE=21000"
  mkdir -p "$XDG_CONFIG_HOME/systemd/user"
  linux write_octane_unit app
  assert_contains "$(cat "$XDG_CONFIG_HOME/systemd/user/vhosty-octane-app.service")" "WorkingDirectory=$HOME/My100%%/app"
}

@test "units of sites no longer on Octane are found" {
  octane_site escrow
  site_conf escrow "SITE_OCTANE=21000"
  mkdir -p "$XDG_CONFIG_HOME/systemd/user"
  touch "$XDG_CONFIG_HOME/systemd/user/vhosty-octane-escrow.service" "$XDG_CONFIG_HOME/systemd/user/vhosty-octane-old.service"
  [ "$(linux sd_stale_octane)" = old ]
}

@test "the launchd daemon runs in the site's folder, with https links" {
  export VHOSTY_DAEMON_DIR="$HOME/LaunchDaemons" VHOSTY_BREW_PREFIX="$HOME/brew"
  mkdir -p "$VHOSTY_DAEMON_DIR" "$HOME/brew/bin"
  stub sudo '[ "$1" = tee ] && exec "$@"; exit 0'
  mkdir -p "$HOME/R&D/app/public"
  site_conf app "SITE_PATH=\"$HOME/R&D/app\"
SITE_LINKED=yes
SITE_OCTANE=21000"
  mac write_plist octane-app
  plist="$(cat "$VHOSTY_DAEMON_DIR/link.vhosty.octane-app.plist")"
  assert_contains "$plist" "<key>WorkingDirectory</key><string>$HOME/R&amp;D/app</string>"
  assert_contains "$plist" "<key>OCTANE_HTTPS</key><string>true</string>"
  assert_contains "$plist" "<key>PHP_INI_SCAN_DIR</key><string>:$VHOSTY_DIR/octane/app</string>"
  assert_contains "$plist" "<key>PWD</key><string>$HOME/R&amp;D/app</string>"
  assert_contains "$plist" "<string>octane:start</string>"
  assert_contains "$plist" "$VHOSTY_DIR/logs/octane-app.log"
}

@test "other launchd daemons are written as before" {
  export VHOSTY_DAEMON_DIR="$HOME/LaunchDaemons"
  mkdir -p "$VHOSTY_DAEMON_DIR"
  stub sudo '[ "$1" = tee ] && exec "$@"; exit 0'
  mac write_plist caddy
  plist="$(cat "$VHOSTY_DAEMON_DIR/link.vhosty.caddy.plist")"
  assert_contains "$plist" "<key>WorkingDirectory</key><string>$VHOSTY_DIR</string>"
  refute_contains "$plist" "OCTANE_HTTPS"
}

@test "the workers get the global settings, and the site's over them" {
  octane_site escrow
  printf 'memory_limit = -1\nupload_max_filesize = 128M\n' >"$VHOSTY_DIR/php.ini"
  site_conf escrow "SITE_OCTANE=21000
SITE_INI='upload_max_filesize=64M
error_reporting=E_ALL & ~E_NOTICE'"
  vh write_configs
  ini="$(cat "$VHOSTY_DIR/octane/escrow/vhosty.ini")"
  assert_contains "$ini" "memory_limit = -1"
  assert_contains "$ini" "upload_max_filesize = 64M"
  refute_contains "$ini" "128M"
  # Unquoted, or PHP wouldn't work out the constants
  assert_contains "$ini" "error_reporting = E_ALL & ~E_NOTICE"
}

@test "a site with no settings of its own still gets a valid file" {
  octane_site escrow
  printf 'memory_limit = -1\n' >"$VHOSTY_DIR/php.ini"
  site_conf escrow "SITE_OCTANE=21000"
  vh write_configs
  [ "$(grep -c '^memory_limit = -1$' "$VHOSTY_DIR/octane/escrow/vhosty.ini")" = 1 ]
  refute grep -q '^ *=' "$VHOSTY_DIR/octane/escrow/vhosty.ini"
}

@test "the settings of a site no longer on Octane are removed" {
  octane_site escrow
  mkdir -p "$VHOSTY_DIR/octane/old"
  touch "$VHOSTY_DIR/octane/old/vhosty.ini"
  site_conf escrow "SITE_OCTANE=21000"
  vh write_configs
  [ -f "$VHOSTY_DIR/octane/escrow/vhosty.ini" ]
  [ ! -d "$VHOSTY_DIR/octane/old" ]
}

@test "a changed setting counts as drift, and checking doesn't change the file" {
  octane_site escrow
  printf 'memory_limit = -1\n' >"$VHOSTY_DIR/php.ini"
  site_conf escrow "SITE_OCTANE=21000"
  vh write_configs
  vh config_in_sync
  printf 'memory_limit = 256M\n' >"$VHOSTY_DIR/php.ini"
  run vh config_in_sync
  [ "$status" -ne 0 ]
  assert_contains "$(cat "$VHOSTY_DIR/octane/escrow/vhosty.ini")" "memory_limit = -1"
}

@test "FrankenPHP gets Octane's Caddyfile, listening on localhost only" {
  octane_site escrow
  mkdir -p "$PARKED/escrow/vendor/laravel/octane/src/Commands/stubs"
  printf '{\n\t{$CADDY_GLOBAL_OPTIONS}\n\tadmin x\n}\n{$CADDY_SERVER_SERVER_NAME} {\n}\n' >"$PARKED/escrow/vendor/laravel/octane/src/Commands/stubs/Caddyfile"
  site_conf escrow "SITE_OCTANE=21000"
  vh write_configs
  conf="$VHOSTY_DIR/octane/escrow/Caddyfile"
  [ "$(sed -n 2p "$conf")" = "$(printf '\tdefault_bind 127.0.0.1')" ]
  assert_contains "$(cat "$conf")" 'admin x'
  run vh octane_cmd escrow
  assert_contains "$output" "--caddyfile=$conf"
}

@test "without Octane's Caddyfile there's no flag pointing at a missing file" {
  octane_site escrow
  site_conf escrow "SITE_OCTANE=21000"
  vh write_configs
  [ ! -f "$VHOSTY_DIR/octane/escrow/Caddyfile" ]
  run vh octane_cmd escrow
  refute_contains "$output" "--caddyfile"
}

@test "the generated Caddyfile is one Caddy accepts" {
  [ -x "$CADDY" ] || skip "no Caddy with the Cloudflare plugin (set VHOSTY_TEST_CADDY)"
  octane_site escrow
  mkdir -p "$PARKED/escrow/vendor/laravel/octane/src/Commands/stubs"
  printf '{\n\tadmin off\n}\nhttp://:18099 {\n\trespond ok\n}\n' >"$PARKED/escrow/vendor/laravel/octane/src/Commands/stubs/Caddyfile"
  site_conf escrow "SITE_OCTANE=21000"
  vh write_configs
  run "$CADDY" adapt --config "$VHOSTY_DIR/octane/escrow/Caddyfile" --adapter caddyfile
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  assert_contains "$output" '127.0.0.1:18099'
}

@test "RoadRunner is told not to serve PHP files" {
  octane_site rr roadrunner
  site_conf rr "SITE_OCTANE=21000"
  vh write_configs
  assert_contains "$(cat "$VHOSTY_DIR/octane/rr/rr.yaml")" 'forbid: [".php"]'
  run vh octane_cmd rr
  assert_contains "$output" "--rr-config=$VHOSTY_DIR/octane/rr/rr.yaml"
}

@test "a project's own .rr.yaml is kept, and doctor says what it needs" {
  octane_site rr roadrunner
  echo 'version: "3"' >"$PARKED/rr/.rr.yaml"
  site_conf rr "SITE_OCTANE=21000"
  vh write_configs
  [ ! -f "$VHOSTY_DIR/octane/rr/rr.yaml" ]
  run vh octane_cmd rr
  refute_contains "$output" "--rr-config"
  stub curl 'printf 000'
  run vh octane_checks
  assert_contains "$output" 'http.static.forbid'
}

@test "doctor fails a site that answers on the tailnet address" {
  octane_site escrow
  site_conf escrow "SITE_OCTANE=21000"
  stub curl 'printf 200'
  run vh octane_checks
  assert_contains "$output" "answers on 100.64.0.7:21000, not just localhost"
}

@test "doctor is quiet about a site only localhost can reach" {
  octane_site escrow
  site_conf escrow "SITE_OCTANE=21000"
  stub curl 'case "$*" in *127.0.0.1*) printf 200 ;; *) printf 000 ;; esac'
  run vh octane_checks
  assert_contains "$output" "escrow answers on port 21000"
  refute_contains "$output" "not just localhost"
}

@test "doctor says when a Swoole site's PHP has no Swoole" {
  octane_site escrow swoole
  site_conf escrow "SITE_OCTANE=21000"
  stub curl 'printf 000'
  cat >"$HOME/run.sh" <<'SH'
source "$VHOSTY_SRC"; PLATFORM=linux; load_config
ext_loaded() { return 1; }
octane_checks
SH
  run env VHOSTY_SRC="$ROOT/bin/vhosty" bash "$HOME/run.sh"
  assert_contains "$output" "vhosty ext install swoole --php 8.4"
}

@test "a stale unit counts as drift" {
  octane_site escrow
  site_conf escrow "SITE_OCTANE=21000"
  mkdir -p "$XDG_CONFIG_HOME/systemd/user"
  touch "$XDG_CONFIG_HOME/systemd/user/vhosty-caddy.service"
  linux write_configs
  linux write_octane_unit escrow
  linux config_in_sync
  echo '# changed' >>"$XDG_CONFIG_HOME/systemd/user/vhosty-octane-escrow.service"
  run linux config_in_sync
  [ "$status" -ne 0 ]
}

@test "a rebuild removes the unit and files of a site no longer on Octane" {
  octane_site escrow
  mkdir -p "$XDG_CONFIG_HOME/systemd/user" "$VHOSTY_DIR/octane/escrow"
  touch "$XDG_CONFIG_HOME/systemd/user/vhosty-octane-escrow.service"
  stub systemctl 'echo "systemctl $*" >>"$HOME/systemctl.log"'
  linux write_configs
  [ ! -d "$VHOSTY_DIR/octane/escrow" ]
  linux svc_sync
  [ ! -f "$XDG_CONFIG_HOME/systemd/user/vhosty-octane-escrow.service" ]
  assert_contains "$(cat "$HOME/systemctl.log")" "disable --now --quiet vhosty-octane-escrow.service"
}

@test "installing an extension restarts Octane on that PHP version, and not others" {
  octane_site here
  octane_site there
  site_conf here "SITE_OCTANE=21000"
  site_conf there "SITE_OCTANE=21001
SITE_PHP=8.3"
  cat >"$HOME/run.sh" <<'SH'
source "$VHOSTY_SRC"; PLATFORM=linux; load_config
php_is_installed() { return 0; }
svc_running() { return 0; }
svc_restart() { echo "restart $1"; }
octane_restart_php 8.4
SH
  run env VHOSTY_SRC="$ROOT/bin/vhosty" bash "$HOME/run.sh"
  assert_contains "$output" "restart octane-here"
  refute_contains "$output" "octane-there"
}

@test "a free port skips other sites' and what's listening" {
  php_site escrow
  site_conf escrow "SITE_OCTANE=21000"
  stub ss 'case "$*" in *:21001*) echo "LISTEN 0 0 127.0.0.1:21001 0.0.0.0:* users:((\"x\",pid=1,fd=1))" ;; esac'
  [ "$(linux octane_free_port)" = 21002 ]
}

@test "a port set aside by vhosty link isn't handed out again" {
  php_site escrow
  printf 'SITE_OCTANE=21000\n' >"$VHOSTY_DIR/sites/foo.conf.parked"
  stub ss 'exit 0'
  [ "$(linux octane_free_port)" = 21001 ]
}

@test "octane on: zero workers is refused" {
  octane_site escrow
  run linux cmd_octane_on escrow --workers 0
  [ "$status" -ne 0 ]
  assert_contains "$output" "1 or more"
}

@test "octane on: a site without Octane installed is told how" {
  php_site escrow
  run linux cmd_octane_on escrow
  [ "$status" -ne 0 ]
  assert_contains "$output" "composer require laravel/octane"
  [ ! -f "$VHOSTY_DIR/sites/escrow.conf" ]
}

@test "octane on: saves the port and the workers, and routes the site" {
  octane_site escrow
  stub ss 'exit 0'   # nothing listening, whatever this machine runs
  run linux cmd_octane_on escrow --workers 3
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  assert_contains "$(cat "$VHOSTY_DIR/sites/escrow.conf")" "SITE_OCTANE=21000"
  assert_contains "$(cat "$VHOSTY_DIR/sites/escrow.conf")" "SITE_OCTANE_WORKERS=3"
  assert_contains "$(cat "$VHOSTY_DIR/Caddyfile")" "reverse_proxy 127.0.0.1:21000"
  [ ! -f "$HOME/php.log" ]   # the server was already there: nothing to download
}

@test "octane on again keeps the port" {
  octane_site escrow
  site_conf escrow "SITE_OCTANE=21005"
  run linux cmd_octane_on escrow
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  assert_contains "$(cat "$VHOSTY_DIR/sites/escrow.conf")" "SITE_OCTANE=21005"
}

@test "octane on: a server that isn't downloaded is, before the service needs it" {
  octane_site escrow
  rm "$PARKED/escrow/frankenphp"
  export PATH="$HOME/stubs:/usr/bin:/bin"
  command -v frankenphp >/dev/null && skip "frankenphp is in /usr/bin here"
  run linux octane_prepare escrow "$PARKED/escrow"
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  assert_contains "$(cat "$HOME/php.log")" "php artisan octane:install --server=frankenphp --no-interaction"
}

@test "octane on: no server picked says to pick one, and doesn't choose for you" {
  octane_site escrow
  rm "$PARKED/escrow/.env"
  run linux octane_prepare escrow "$PARKED/escrow"
  [ "$status" -ne 0 ]
  assert_contains "$output" "php artisan octane:install"
  [ ! -f "$HOME/php.log" ]
}

@test "octane on: Swoole without its extension says what to install" {
  octane_site escrow swoole
  cat >"$HOME/run.sh" <<'SH'
source "$VHOSTY_SRC"; PLATFORM=linux; load_config
ext_loaded() { return 1; }
octane_prepare escrow "$1"
SH
  run env VHOSTY_SRC="$ROOT/bin/vhosty" bash "$HOME/run.sh" "$PARKED/escrow"
  [ "$status" -ne 0 ]
  assert_contains "$output" "vhosty ext install swoole --php 8.4"
}

@test "octane off goes back to PHP-FPM, and keeps the site's other settings" {
  octane_site escrow
  site_conf escrow "SITE_PHP=8.4
SITE_OCTANE=21000"
  run linux cmd_octane_off escrow
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  assert_contains "$(cat "$VHOSTY_DIR/sites/escrow.conf")" "SITE_PHP=8.4"
  refute_contains "$(cat "$VHOSTY_DIR/sites/escrow.conf")" "SITE_OCTANE=21000"
  refute_contains "$(cat "$VHOSTY_DIR/Caddyfile")" "vhosty_kind octane"
}

@test "octane off on a site that isn't on it says so" {
  php_site escrow
  run linux cmd_octane_off escrow
  [ "$status" -ne 0 ]
  assert_contains "$output" "doesn't run on Octane"
}

@test "octane reload runs artisan in the site's folder" {
  octane_site escrow
  site_conf escrow "SITE_OCTANE=21000"
  run linux cmd_octane_reload escrow
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  assert_contains "$(cat "$HOME/php.log")" "php artisan octane:reload (in $PARKED/escrow)"
}

@test "with Herd, Octane points at the port route" {
  write_config 'VHOSTY_BACKEND="herd"'
  run vh main octane on
  [ "$status" -ne 0 ]
  assert_contains "$output" "octane:start"
}

@test "the site's details say it's on Octane, and what FrankenPHP means" {
  octane_site escrow
  site_conf escrow "SITE_OCTANE=21000"
  stub systemctl 'echo inactive'
  stub php8.4 'exit 0'
  run linux cmd_site escrow
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  assert_contains "$output" "Laravel Octane"
  assert_contains "$output" "frankenphp, port 21000, 2 workers"
  assert_contains "$output" "FrankenPHP has its own PHP"
}

# --- Through a real Caddy ----------------------------------------------------

# A stand-in for Octane: answers with the request's Host and X-Forwarded-*
start_octane() {
  mkdir -p "$HOME/fake-octane"
  cat >"$HOME/fake-octane/server.py" <<'PY'
import http.server, sys
class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def do_GET(self):
        body = "host=%s xfh=%s xfp=%s\n" % (self.headers.get("Host"), self.headers.get("X-Forwarded-Host"), self.headers.get("X-Forwarded-Proto"))
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body.encode())
    def log_message(self, *a): pass
http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
  python3 -I "$HOME/fake-octane/server.py" "$OCTANE_PORT" >"$HOME/fake-octane/log" 2>&1 &
  OCTANE_PID=$!
  for _ in $(seq 1 50); do
    curl -s -o /dev/null "http://127.0.0.1:$OCTANE_PORT/" && return 0
    sleep 0.1
  done
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

@test "Octane gets the site's real name, and the forwarded headers" {
  [ -x "$CADDY" ] || skip "no Caddy with the Cloudflare plugin (set VHOSTY_TEST_CADDY)"
  command -v python3 >/dev/null || skip "no python3 for the fake Octane"
  php_site escrow
  site_conf escrow "SITE_OCTANE=$OCTANE_PORT"
  start_octane
  start_caddy
  run curl -s -H "Host: escrow.test.example" "http://127.0.0.1:$PORT/"
  assert_contains "$output" "host=escrow.test.example"
  assert_contains "$output" "xfh=escrow.test.example"
}

@test "Octane not answering gets vhosty's page, with its service's name" {
  [ -x "$CADDY" ] || skip "no Caddy with the Cloudflare plugin (set VHOSTY_TEST_CADDY)"
  php_site escrow
  site_conf escrow "SITE_OCTANE=$OCTANE_PORT"
  start_caddy
  run curl -s -w '\n%{http_code}' -H "Host: escrow.test.example" "http://127.0.0.1:$PORT/"
  assert_contains "$output" "Octane isn't answering"
  assert_contains "$output" "vhosty restart octane-escrow"
  assert_contains "$output" "502"
}
