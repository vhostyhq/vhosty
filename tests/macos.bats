#!/usr/bin/env bats
# vhosty's own mode on macOS: PHP from Homebrew, Caddy behind Tailscale Serve,
# and log rotation from launchd. Runs anywhere: `mac` runs one of vhosty's
# functions as if on macOS, with a fake Homebrew (shell scripts standing in for
# its PHP binaries, and a brew that logs what it's asked).

load helpers

# Found before vhosty_setup points HOME at a scratch folder
CADDY="${VHOSTY_TEST_CADDY:-$HOME/.vhosty/bin/caddy}"

setup() {
  vhosty_setup
  export VHOSTY_BREW_PREFIX="$HOME/brew"
  BREW="$VHOSTY_BREW_PREFIX"
  mkdir -p "$BREW/bin" "$BREW/opt"
  brew_stub
  # The newest stable is plain php (opt/php), older ones php@X.Y
  brew_php php 8.5.12_1
  brew_php php@8.4 8.4.27
}

# mac FUNCTION [ARGS...]: like vh, as if on macOS
mac() {
  VHOSTY_SRC="$ROOT/bin/vhosty" "${VHOSTY_TEST_BASH:-bash}" -c 'source "$VHOSTY_SRC"; PLATFORM=macos; trap cleanup_tmp EXIT; load_config; "$@"' vh "$@"
}

# brew_php FORMULA VERSION: a keg in Cellar, linked from opt/ as Homebrew does.
# Its php -m lists MODULES (default: Core, pdo_pgsql).
brew_php() {
  local cellar="$BREW/Cellar/$1/$2"
  mkdir -p "$cellar/sbin" "$cellar/bin"
  printf '#!/usr/bin/env bash\necho "PHP %s (fpm-fcgi)"\n' "${2%_*}" >"$cellar/sbin/php-fpm"
  printf '#!/usr/bin/env bash\nif [ "${1:-}" = -m ]; then printf "%%s\\n" Core pdo_pgsql $(cat "%s/modules" 2>/dev/null); exit; fi\necho "php %s $*"\n' "$cellar" "${2%_*}" >"$cellar/bin/php"
  chmod +x "$cellar/sbin/php-fpm" "$cellar/bin/php"
  ln -sfn "../Cellar/$1/$2" "$BREW/opt/$1"
}

# brew: logs its arguments; `brew info` knows the formulas in $HOME/formulas;
# `brew install shivammathur/php/php@X.Y` installs a keg
brew_stub() {
  cat >"$BREW/bin/brew" <<EOF
#!/usr/bin/env bash
echo "brew \$*" >>"$HOME/brew.log"
case "\$1" in
  list) cat "$HOME/installed" 2>/dev/null ;;
  info) grep -qxF "\$2" "$HOME/formulas" 2>/dev/null; exit ;;
  install)
    case "\$2" in
      shivammathur/php/php@*) v="\${2##*@}"; c="$BREW/Cellar/php@\$v/\$v.1"
        mkdir -p "\$c/sbin" "\$c/bin"; printf '#!/usr/bin/env bash\necho "PHP \$v.1"\n' >"\$c/sbin/php-fpm"
        printf '#!/usr/bin/env bash\necho Core\n' >"\$c/bin/php"; chmod +x "\$c/sbin/php-fpm" "\$c/bin/php"
        ln -sfn "../Cellar/php@\$v/\$v.1" "$BREW/opt/php@\$v" ;;
    esac ;;
esac
exit 0
EOF
  chmod +x "$BREW/bin/brew"
}

static_build() { # an old vhosty's static PHP-FPM in ~/.vhosty/bin
  mkdir -p "$VHOSTY_DIR/bin"
  printf '#!/usr/bin/env bash\necho "PHP %s.9 (fpm-fcgi)"\n' "$1" >"$VHOSTY_DIR/bin/php-fpm-$1"
  chmod +x "$VHOSTY_DIR/bin/php-fpm-$1"
}

# --- PHP from Homebrew -------------------------------------------------------

@test "Homebrew's PHP versions are found, opt/php as the version it points at" {
  run mac php_installed_versions
  [ "$output" = "$(printf '8.5\n8.4')" ]
  [ "$(mac fpm_bin 8.4)" = "$BREW/opt/php@8.4/sbin/php-fpm" ]
  [ "$(mac fpm_bin 8.5)" = "$BREW/opt/php/sbin/php-fpm" ]
  [ "$(mac php_cli 8.5)" = "$BREW/opt/php/bin/php" ]
  [ "$(mac brew_php_formula 8.5)" = php ]
  [ "$(mac brew_php_formula 8.4)" = php@8.4 ]
}

@test "a php@X.Y keg wins over opt/php of the same version" {
  brew_php php@8.5 8.5.12
  [ "$(mac fpm_bin 8.5)" = "$BREW/opt/php@8.5/sbin/php-fpm" ]
  [ "$(mac php_installed_versions | grep -c '^8\.5$')" -eq 1 ]
}

@test "an old static build still counts, until Homebrew has that version" {
  static_build 8.3
  static_build 8.4
  run mac php_installed_versions
  [ "$output" = "$(printf '8.5\n8.4\n8.3')" ]
  [ "$(mac fpm_bin 8.3)" = "$VHOSTY_DIR/bin/php-fpm-8.3" ]
  [ "$(mac fpm_bin 8.4)" = "$BREW/opt/php@8.4/sbin/php-fpm" ]
  mac php_is_static 8.3
  run mac php_is_static 8.4
  [ "$status" -ne 0 ]
  assert_contains "$(mac ext_fix redis 8.3)" "vhosty php install 8.3"
  assert_contains "$(mac ext_fix redis 8.4)" "vhosty ext install redis --php 8.4"
}

@test "extensions are checked against the version's own CLI" {
  [ "$(mac php_bin_for 8.4)" = "$BREW/opt/php@8.4/bin/php" ]
  static_build 8.3
  [ "$(mac php_bin_for 8.3)" = "$VHOSTY_DIR/bin/php-fpm-8.3" ]
  mac ext_loaded 8.4 pdo_pgsql
  run mac ext_loaded 8.4 redis
  [ "$status" -ne 0 ]
}

@test "php-X.Y links to each Homebrew version's CLI, and a link to a removed one goes" {
  mac brew_link_clis
  [ "$(readlink "$VHOSTY_DIR/bin/php-8.4")" = "$BREW/opt/php@8.4/bin/php" ]
  [ "$(readlink "$VHOSTY_DIR/bin/php-8.5")" = "$BREW/opt/php/bin/php" ]
  rm "$BREW/opt/php@8.4"
  mac brew_link_clis
  [ ! -e "$VHOSTY_DIR/bin/php-8.4" ] && [ ! -L "$VHOSTY_DIR/bin/php-8.4" ]
}

@test "the php shim runs Homebrew's CLI for the site's version, opt/php included" {
  php_site app
  site_conf app "SITE_PHP=8.5"
  # a PATH without the system's php, as on a Mac
  mkdir -p "$HOME/nophp"
  for t in bash env sed tr cat uname id awk grep sort head cut mktemp rm readlink; do ln -s "$(command -v "$t")" "$HOME/nophp/$t"; done
  mac write_shim
  shim="$(cat "$VHOSTY_DIR/bin/php")"
  assert_contains "$shim" "lv=8.5"
  cd "$PARKED/app"
  [ "$(PATH="$HOME/nophp" "$VHOSTY_DIR/bin/php" -r 1 | awk '{print $1, $2}')" = "php 8.5.12" ] \
    || ! [ -x /usr/bin/php8.5 ]   # a Linux box with apt's 8.5 finds that first
  cd "$HOME"
  [ "$(PATH="$HOME/nophp" VHOSTY_PHP_VERSION=8.4 "$VHOSTY_DIR/bin/php" -r 1 | awk '{print $1, $2}')" = "php 8.4.27" ] \
    || [ -x /usr/bin/php8.4 ]
}

@test "php install: taps shivammathur/php, installs php@X.Y and the extensions apt's packages have" {
  echo shivammathur/extensions/redis@8.3 >"$HOME/formulas"
  echo shivammathur/extensions/igbinary@8.3 >>"$HOME/formulas"
  run mac install_php_fpm 8.3
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  log="$(cat "$HOME/brew.log")"
  assert_contains "$log" "brew tap shivammathur/php"
  assert_contains "$log" "brew install shivammathur/php/php@8.3"
  assert_contains "$log" "brew install shivammathur/extensions/redis@8.3"
  assert_contains "$log" "brew install shivammathur/extensions/igbinary@8.3"
  [ "$(mac fpm_bin 8.3)" = "$BREW/opt/php@8.3/sbin/php-fpm" ]
}

@test "php install moves an old static build to Homebrew" {
  static_build 8.3
  run mac install_php_fpm 8.3
  assert_contains "$output" "removed vhosty's old static build of PHP 8.3"
  [ ! -e "$VHOSTY_DIR/bin/php-fpm-8.3" ]
  run mac php_is_static 8.3
  [ "$status" -ne 0 ]
}

@test "php install says how to get Homebrew when there isn't one" {
  run mac eval 'brew_cmd() { :; }; install_php_fpm 8.3'
  [ "$status" -ne 0 ]
  assert_contains "$output" "https://brew.sh"
}

@test "ext install: shivammathur/extensions when it has the extension, else that version's pecl" {
  echo shivammathur/extensions/redis@8.4 >"$HOME/formulas"
  printf '#!/usr/bin/env bash\necho "pecl $*" >>"%s/brew.log"\n' "$HOME" >"$BREW/opt/php@8.4/bin/pecl"
  chmod +x "$BREW/opt/php@8.4/bin/pecl"
  run mac install_exts 8.4 redis spx
  log="$(cat "$HOME/brew.log")"
  assert_contains "$log" "brew tap shivammathur/extensions"
  assert_contains "$log" "brew install shivammathur/extensions/redis@8.4"
  assert_contains "$log" "pecl install spx"
  refute_contains "$log" "brew install shivammathur/extensions/spx@8.4"
}

@test "ext install skips what the version already has" {
  run mac install_exts 8.4 pdo_pgsql
  assert_contains "$output" "pdo_pgsql (already there)"
  refute_contains "$(cat "$HOME/brew.log")" "install"
}

@test "ext install refuses an old static build, and says how to move it" {
  static_build 8.3
  run mac install_exts 8.3 redis
  [ "$status" -ne 0 ]
  assert_contains "$output" "vhosty php install 8.3"
}

@test "update php upgrades the version's formula and its extension formulas" {
  printf '%s\n' php php@8.4 redis@8.4 xdebug@8.5 igbinary@8.4 >"$HOME/installed"
  run mac update_php 8.4
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  assert_contains "$(cat "$HOME/brew.log")" "brew upgrade php@8.4 redis@8.4 igbinary@8.4"
}

# --- Caddy behind Tailscale Serve ----------------------------------------------

@test "on macOS, Caddy listens on localhost's 48443 and 48080, and redirects http itself" {
  mac write_configs
  caddyfile="$(cat "$VHOSTY_DIR/Caddyfile")"
  run grep -E '^\s*default_bind' "$VHOSTY_DIR/Caddyfile"
  [ "$output" = "$(printf '\tdefault_bind 127.0.0.1')" ]
  assert_contains "$caddyfile" "https_port 48443"
  assert_contains "$caddyfile" "http_port 48080"
  assert_contains "$caddyfile" "auto_https disable_redirects"
  assert_contains "$caddyfile" "http://*.test.example {
	redir https://{host}{uri} permanent
}"
  # the folder sites are vhosty's own, as on Linux
  assert_contains "$caddyfile" "php_fastcgi"
}

@test "on macOS, the ports are settings" {
  write_config 'VHOSTY_SERVE_PORT="49443"
VHOSTY_SERVE_HTTP_PORT="49080"'
  mac write_configs
  assert_contains "$(cat "$VHOSTY_DIR/Caddyfile")" "https_port 49443"
  [ "$(mac serve_pairs)" = "443:49443 80:49080" ]
}

@test "on macOS, the ports are saved with the config; on Linux they aren't" {
  mac save_config
  grep -q '^VHOSTY_SERVE_PORT=48443$' "$VHOSTY_DIR/config"
  vh save_config
  run grep -q SERVE "$VHOSTY_DIR/config"
  [ "$status" -ne 0 ]
}

@test "on macOS, the Caddyfile doesn't depend on the Tailscale address" {
  mac write_configs
  before="$(cat "$VHOSTY_DIR/Caddyfile")"
  stub tailscale 'exit 1'
  mac write_configs
  [ "$(cat "$VHOSTY_DIR/Caddyfile")" = "$before" ]
  run mac drift_reason
  [ "$output" = "settings changed since the last rebuild" ]
}

@test "on Linux, Caddy still listens on the Tailscale address and localhost" {
  vh write_configs
  caddyfile="$(cat "$VHOSTY_DIR/Caddyfile")"
  assert_contains "$caddyfile" "default_bind 100.64.0.7 127.0.0.1 ::1"
  refute_contains "$caddyfile" "https_port"
  refute_contains "$caddyfile" "http://"
}

@test "the macOS Caddyfile is valid" {
  [ -x "$CADDY" ] || skip "no Caddy with the Cloudflare plugin (set VHOSTY_TEST_CADDY)"
  php_site app
  mac write_configs
  CF_API_TOKEN=0123456789abcdef0123456789abcdef01234567 run "$CADDY" validate --config "$VHOSTY_DIR/Caddyfile" --adapter caddyfile
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
}

# A fake tailscale whose Serve config is kept as "port target" lines, and
# printed as JSON the way the real one prints it. serve_stub [JSON] starts
# from that JSON instead (something else on Serve).
serve_stub() {
  : >"$HOME/serve.tcp"
  if [ -n "${1:-}" ]; then printf '%s\n' "$1" >"$HOME/serve.json"; else echo '{}' >"$HOME/serve.json"; fi
  stub tailscale '
tcp="$HOME/serve.tcp"; st="$HOME/serve.json"
echo "$*" >>"$HOME/tailscale.log"
write() {
  { printf "{\n  \"TCP\": {"; sep=""
    while read -r p t; do printf "%s\n    \"%s\": {\n      \"TCPForward\": \"%s\"\n    }" "$sep" "$p" "$t"; sep=","; done <"$tcp"
    printf "\n  }\n}\n"; } >"$st"
}
case "$*" in
  ip*) echo 100.64.0.7 ;;
  "serve status --json") cat "$st" ;;
  "serve status") echo "(serve status)" ;;
  "serve --bg --tcp="*) p="${3#--tcp=}"; grep -v "^$p " "$tcp" >"$tcp.new"; echo "$p ${4#tcp://}" >>"$tcp.new"; mv "$tcp.new" "$tcp"; write ;;
  "serve --https="*" off"|"serve --http="*" off"|"serve --tcp="*" off")
    p="${2#*=}"; grep -v "^$p " "$tcp" >"$tcp.new" || true; mv "$tcp.new" "$tcp"; write ;;
  *) echo "unexpected: $*" >&2; exit 1 ;;
esac'
}

@test "Tailscale Serve passes the tailnet's 443 and 80 to Caddy" {
  serve_stub
  mac serve_on
  mac serve_ok
  log="$(cat "$HOME/tailscale.log")"
  assert_contains "$log" "serve --bg --tcp=443 tcp://127.0.0.1:48443"
  assert_contains "$log" "serve --bg --tcp=80 tcp://127.0.0.1:48080"
}

@test "Tailscale Serve already passing both ports to Caddy is left alone" {
  serve_stub '{"TCP":{"443":{"TCPForward":"127.0.0.1:48443"},"80":{"TCPForward":"127.0.0.1:48080"}}}'
  mac serve_on
  refute_contains "$(cat "$HOME/tailscale.log")" "--bg"
}

@test "an older setup with only 443 on Serve gets 80 added" {
  serve_stub
  printf '443 127.0.0.1:48443\n' >"$HOME/serve.tcp"
  printf '{"TCP":{"443":{"TCPForward":"127.0.0.1:48443"}}}\n' >"$HOME/serve.json"
  run mac serve_ok
  [ "$status" -ne 0 ]
  run mac serve_on
  [ "$status" -eq 0 ]
  refute_contains "$output" "already uses"
  log="$(cat "$HOME/tailscale.log")"
  refute_contains "$log" "--tcp=443 tcp://"
  assert_contains "$log" "serve --bg --tcp=80 tcp://127.0.0.1:48080"
  mac serve_ok
}

@test "something else on Tailscale Serve's 443 is replaced, once you say yes" {
  serve_stub '{"TCP":{"443":{"HTTPS":true}},"Web":{"box.tail1.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8000"}}}}}'
  run mac serve_on </dev/null   # no terminal: the default, yes
  [ "$status" -eq 0 ]
  assert_contains "$output" "already uses port 443"
  assert_contains "$output" "Replacing it turns that off"
  assert_contains "$output" "tailscale serve --bg --https=8443 http://127.0.0.1:8000"
  assert_contains "$(cat "$HOME/tailscale.log")" "serve --https=443 off"
  mac serve_ok
}

@test "Tailscale Serve refusing (Serve not enabled) stops with its message" {
  stub tailscale 'case "$*" in ip*) echo 100.64.0.7 ;; "serve status --json") echo "{}" ;; *) echo "Serve is not enabled on your tailnet. To enable, visit: https://login.tailscale.com/f/serve" >&2; exit 1 ;; esac'
  run mac serve_on
  [ "$status" -ne 0 ]
  assert_contains "$output" "Serve is not enabled on your tailnet"
}

@test "uninstall's Serve cleanup only removes vhosty's forwards" {
  serve_stub '{"TCP":{"443":{"HTTPS":true}}}'
  mac serve_off
  [ ! -f "$HOME/tailscale.log" ] || refute_contains "$(cat "$HOME/tailscale.log")" "off"
  serve_stub
  printf '443 127.0.0.1:48443\n80 127.0.0.1:48080\n' >"$HOME/serve.tcp"
  printf '{"TCP":{"443":{"TCPForward":"127.0.0.1:48443"},"80":{"TCPForward":"127.0.0.1:48080"}}}\n' >"$HOME/serve.json"
  mac serve_off
  log="$(cat "$HOME/tailscale.log")"
  assert_contains "$log" "serve --tcp=443 off"
  assert_contains "$log" "serve --tcp=80 off"
}

# --- launchd --------------------------------------------------------------------

@test "logs rotate daily from a launchd daemon, which isn't removed as stale" {
  export VHOSTY_DAEMON_DIR="$HOME/LaunchDaemons"
  mkdir -p "$VHOSTY_DAEMON_DIR"
  stub sudo '[ "$1" = tee ] && exec "$@"; exit 0'
  mac write_logs_plist
  plist="$(cat "$VHOSTY_DAEMON_DIR/link.vhosty.logs.plist")"
  assert_contains "$plist" "<string>$VHOSTY_DIR/bin/vhosty</string>"
  assert_contains "$plist" "<string>rotate</string>"
  assert_contains "$plist" "StartCalendarInterval"
  touch "$VHOSTY_DAEMON_DIR/link.vhosty.php-7.4.plist"
  [ "$(mac launchd_stale)" = "php-7.4" ]
}
