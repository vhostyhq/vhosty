#!/usr/bin/env bats
# The generated Caddyfile, PHP-FPM config and error page

load helpers

caddyfile() { vh write_caddyfile && cat "$VHOSTY_DIR/Caddyfile"; }

@test "Caddy listens on the Tailscale address and localhost only" {
  run caddyfile
  assert_contains "$output" "default_bind 100.64.0.7 127.0.0.1 ::1"
}

@test "the site block covers the wildcard and gets its certificate over DNS" {
  run caddyfile
  assert_contains "$output" "*.test.example {"
  assert_contains "$output" "dns cloudflare {env.CF_API_TOKEN}"
}

@test "parked folders are matched by the subdomain label" {
  run caddyfile
  # test.example has 2 labels, so the site name is label 2
  assert_contains "$output" "root \"$PARKED/{labels.2}/public\""
  assert_contains "$output" "php_fastcgi \"unix/$VHOSTY_DIR/run/php-8.4.sock\""
  assert_contains "$output" "root \"$PARKED/{labels.2}\""
}

@test "a deeper domain shifts the label" {
  write_config 'VHOSTY_DOMAIN="box.test.example"'
  run caddyfile
  assert_contains "$output" "{labels.3}"
}

@test "a configured site gets its own rule, before the parked ones" {
  php_site escrow
  site_conf escrow "SITE_PHP=8.4"
  run caddyfile
  assert_contains "$output" "@site_escrow host escrow.test.example"
  # its rule comes before the parked wildcard rules
  site_line="$(grep -n '@site_escrow host' "$VHOSTY_DIR/Caddyfile" | cut -d: -f1)"
  parked_line="$(grep -n '@php0 file' "$VHOSTY_DIR/Caddyfile" | cut -d: -f1)"
  [ "$site_line" -lt "$parked_line" ]
}

@test "a site with its own settings uses its own FPM socket" {
  php_site kudos
  site_conf kudos "SITE_INI='memory_limit=1G'"
  run caddyfile
  assert_contains "$output" "php_fastcgi \"unix/$VHOSTY_DIR/run/site-kudos.sock\""
}

@test "a static configured site is served without PHP" {
  static_site docs
  site_conf docs "SITE_EXT=protobuf"
  run caddyfile
  assert_contains "$output" "# Site: docs → $PARKED/docs (static)"
}

@test "a site whose folder is gone is skipped, not served" {
  site_conf gone "SITE_PATH=$HOME/nowhere
SITE_LINKED=yes"
  run caddyfile
  assert_contains "$output" "# Site: gone (skipped: folder $HOME/nowhere not found)"
  refute_contains "$output" "@site_gone"
}

@test "a parked folder with capitals gets a rule for its lowercase name" {
  case "$(uname -s)" in Darwin) skip "macOS folders are case-insensitive" ;; esac
  static_site MyApp
  run caddyfile
  assert_contains "$output" "@site_myapp host myapp.test.example"
  assert_contains "$output" "root * \"$PARKED/MyApp\""
}

@test "routes are tagged for the error pages" {
  php_site escrow
  site_conf escrow "SITE_PHP=8.4"
  run caddyfile
  assert_contains "$output" "vars vhosty_kind port"
  assert_contains "$output" "vhosty_php 8.4"
  assert_contains "$output" "vars vhosty_kind nosite"
  assert_contains "$output" "handle_errors {"
  assert_contains "$output" "vhosty_sites \"escrow\""
  assert_contains "$output" "rewrite * \"$VHOSTY_DIR/error.html\""
}

@test "with PHP off, parked folders are static only" {
  write_config 'VHOSTY_PHP="off"'
  run caddyfile
  refute_contains "$output" "php_fastcgi"
  assert_contains "$output" "try_files index.html"
}

@test "FPM gets a default pool, and a pool for each site with its own settings" {
  printf 'memory_limit = 512M\nmax_execution_time = 60\n' >"$VHOSTY_DIR/php.ini"
  php_site kudos
  site_conf kudos "SITE_INI='memory_limit=1G'"
  vh write_fpm_conf 8.4
  conf="$(cat "$VHOSTY_DIR/php/8.4/php-fpm.conf")"
  assert_contains "$conf" "listen = $VHOSTY_DIR/run/php-8.4.sock"
  assert_contains "$conf" "php_value[memory_limit] = 512M"
  assert_contains "$conf" "[site-kudos]"
  assert_contains "$conf" "listen = $VHOSTY_DIR/run/site-kudos.sock"
  # the site's value replaces the global one in its pool; the rest carry over
  pool="$(sed -n '/^\[site-kudos\]/,$p' "$VHOSTY_DIR/php/8.4/php-fpm.conf")"
  assert_contains "$pool" "php_value[memory_limit] = 1G"
  assert_contains "$pool" "php_value[max_execution_time] = 60"
  refute_contains "$pool" "512M"
}

@test "FPM sockets are readable by their owner only" {
  vh write_fpm_conf 8.4
  assert_contains "$(cat "$VHOSTY_DIR/php/8.4/php-fpm.conf")" "listen.mode = 0600"
}

@test "the error page is a Caddy template with the version baked in" {
  vh write_error_page
  page="$(cat "$VHOSTY_DIR/error.html")"
  version="$(sed -n 's/^VHOSTY_VERSION="\(.*\)"$/\1/p' "$ROOT/bin/vhosty")"
  assert_contains "$page" "{{- \$vhosty := \"$version\" -}}"
  assert_contains "$page" '{{html .Host}}'
  # every value from the request is escaped
  refute_contains "$page" '{{.Host}}'
}

@test "config_in_sync notices a new site and a missing error page" {
  php_site escrow
  vh write_configs
  vh config_in_sync
  site_conf escrow "SITE_PHP=8.3"
  run vh config_in_sync
  [ "$status" -ne 0 ]
  vh write_configs
  vh config_in_sync
  rm "$VHOSTY_DIR/error.html"
  run vh config_in_sync
  [ "$status" -ne 0 ]
}

@test "save_config keeps folder names as text, even with \$(...) or quotes in them" {
  weird="$HOME/a \$(touch $HOME/pwned) \`touch $HOME/pwned2\` \"q\" 'q'"
  VHOSTY_SRC="$ROOT/bin/vhosty" bash -c 'source "$VHOSTY_SRC"; load_config; VHOSTY_PARKED="$1"; save_config' _ "$weird"
  run vh eval 'printf "%s" "$VHOSTY_PARKED"'
  [ "$output" = "$weird" ]
  [ ! -e "$HOME/pwned" ] && [ ! -e "$HOME/pwned2" ]
}

@test "check_folder refuses paths that can't go into the Caddyfile" {
  vh check_folder "$HOME/My Sites"
  vh check_folder "$HOME/it's fine"
  for bad in "$HOME/a\"b" "$HOME/a{b}" "$HOME/a\\b" "$HOME/a
b"; do
    run vh check_folder "$bad"
    [ "$status" -ne 0 ] || { echo "accepted: $bad" >&2; false; }
  done
  vh check_folder "$HOME/a:b"
  run vh check_folder "$HOME/a:b" parked
  [ "$status" -ne 0 ]
}

@test "expand_tilde expands ~ without running anything" {
  [ "$(vh expand_tilde '~')" = "$HOME" ]
  [ "$(vh expand_tilde '~/Sites')" = "$HOME/Sites" ]
  [ "$(vh expand_tilde '/x/$(touch y)')" = '/x/$(touch y)' ]
  [ "$(vh expand_tilde "~/Zack's Sites")" = "$HOME/Zack's Sites" ]
}

@test "the PHP-FPM upstream is quoted, for homes with spaces" {
  php_site escrow
  site_conf escrow "SITE_PHP=8.4"
  run caddyfile
  assert_contains "$output" "php_fastcgi \"unix/$VHOSTY_DIR/run/php-8.4.sock\""
}
