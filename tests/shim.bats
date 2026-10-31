#!/usr/bin/env bats
# The php shim: the version and settings of the site you're in

load helpers

setup_file() { :; }

# Fake PHP binaries the shim finds in ~/.vhosty/bin: they print their version and arguments
fake_php() {
  mkdir -p "$VHOSTY_DIR/bin"
  printf '#!/usr/bin/env bash\necho "php %s $*"\n' "$1" >"$VHOSTY_DIR/bin/php-$1"
  chmod +x "$VHOSTY_DIR/bin/php-$1"
}

shim_setup() {
  write_config 'VHOSTY_PHP_DEFAULT="9.9"'
  fake_php 9.9
  fake_php 9.8
  printf 'memory_limit = 512M\n' >"$VHOSTY_DIR/php.ini"
  vh write_shim
}

@test "outside every site, the shim runs the default version with the global settings" {
  shim_setup
  run bash -c "cd '$HOME' && '$VHOSTY_DIR/bin/php' -v"
  [ "$output" = "php 9.9 -d memory_limit=512M -v" ]
}

@test "inside a pinned site, it runs that site's version and settings" {
  shim_setup
  php_site legacy
  mkdir -p "$PARKED/legacy/app"
  site_conf legacy "SITE_PATH=$PARKED/legacy
SITE_PHP=9.8
SITE_INI='max_execution_time=300'"
  vh write_shim   # the shim has the sites written into it, at rebuild
  run bash -c "cd '$PARKED/legacy/app' && '$VHOSTY_DIR/bin/php' artisan"
  [ "$output" = "php 9.8 -d memory_limit=512M -d max_execution_time=300 artisan" ]
}

@test "the deepest site wins" {
  shim_setup
  mkdir -p "$HOME/p/outer/inner"
  site_conf outer "SITE_PATH=$HOME/p/outer
SITE_LINKED=yes
SITE_PHP=9.9"
  site_conf inner "SITE_PATH=$HOME/p/outer/inner
SITE_LINKED=yes
SITE_PHP=9.8"
  vh write_shim
  run bash -c "cd '$HOME/p/outer/inner' && '$VHOSTY_DIR/bin/php' x"
  assert_contains "$output" "php 9.8"
}

@test "a folder that only starts like a site's path isn't inside it" {
  shim_setup
  mkdir -p "$HOME/p/app" "$HOME/p/app2"
  site_conf app "SITE_PATH=$HOME/p/app
SITE_LINKED=yes
SITE_PHP=9.8"
  vh write_shim
  run bash -c "cd '$HOME/p/app2' && '$VHOSTY_DIR/bin/php' x"
  assert_contains "$output" "php 9.9"
}

@test "VHOSTY_PHP_VERSION overrides the version for one command" {
  shim_setup
  run bash -c "cd '$HOME' && VHOSTY_PHP_VERSION=9.8 '$VHOSTY_DIR/bin/php' x"
  assert_contains "$output" "php 9.8"
}

@test "the shim skips itself however its folder is spelled on the PATH" {
  command -v timeout >/dev/null || skip "no timeout command (macOS)"
  write_config 'VHOSTY_PHP_DEFAULT="9.7"'   # not installed: the shim looks on the PATH
  vh write_shim
  mkdir -p "$HOME/realphp"
  printf '#!/usr/bin/env bash\necho "real php $*"\n' >"$HOME/realphp/php"
  chmod +x "$HOME/realphp/php"
  # the shim's folder with a trailing slash, and through a link, before the real php
  ln -s "$VHOSTY_DIR/bin" "$HOME/binlink"
  run timeout 5 env PATH="$VHOSTY_DIR/bin/:$HOME/binlink:$HOME/realphp:/usr/bin:/bin" "$VHOSTY_DIR/bin/php" -v
  [ "$status" -eq 0 ] || { echo "status $status: $output" >&2; false; }
  [ "$output" = "real php -v" ]
}

@test "a pin that isn't installed falls back to the default version, as the web does" {
  shim_setup
  php_site old
  site_conf old "SITE_PATH=$PARKED/old
SITE_PHP=7.4"
  vh write_shim
  run bash -c "cd '$PARKED/old' && '$VHOSTY_DIR/bin/php' x"
  assert_contains "$output" "php 9.9"
}

@test "folders and settings with spaces and quotes are written into the shim safely" {
  shim_setup
  mkdir -p "$HOME/My Sites/it's here"
  site_conf weird "SITE_PATH='$HOME/My Sites/it'\\''s here'
SITE_LINKED=yes
SITE_PHP=9.8
SITE_INI='error_prepend_string=a \$(touch $HOME/pwned) b'"
  vh write_shim
  bash -n "$VHOSTY_DIR/bin/php"
  run bash -c "cd \"$HOME/My Sites/it's here\" && '$VHOSTY_DIR/bin/php' x"
  assert_contains "$output" "php 9.8"
  assert_contains "$output" "error_prepend_string=a \$(touch $HOME/pwned) b"
  [ ! -e "$HOME/pwned" ]
}

@test "the shim reads no files when it runs" {
  shim_setup
  # no sourcing, and no tools that read files, outside the comments
  ! grep -v '^#' "$VHOSTY_DIR/bin/php" | grep -qE '(^|[;{&|] *)(\.|source|cat|sed|grep|awk) '
}
