#!/usr/bin/env bats
# PHP extension checks: composer.lock requirements and declared extensions

load helpers

# A composer.lock like a Laravel app's: a polyfill provides mbstring
lockfile() {
  mkdir -p "$1"
  cat >"$1/composer.lock" <<'JSON'
{
  "packages": [
    {"name": "laravel/framework", "require": {"php": "^8.2", "ext-mbstring": "*", "ext-openssl": "*", "ext-zend-opcache": "*"}},
    {"name": "intervention/image", "require": {"ext-gd": "*"}},
    {"name": "symfony/polyfill-mbstring", "provide": {"ext-mbstring": "*"}}
  ],
  "packages-dev": [
    {"name": "laravel/horizon", "require": {"ext-pcntl": "*"}}
  ],
  "platform": {"php": "^8.2", "ext-intl": "*"},
  "platform-dev": []
}
JSON
}

# missing DIR 'modules': missing_exts with a fake PHP that has these modules
missing() {
  vh eval 'php_bin_for() { echo /bin/true; }; PHP_MODULES_8_4="$(printf "'"$2"'")"; missing_exts "'"$1"'" 8.4'
}

@test "lock_ext_reqs lists ext-* requirements, less what packages provide" {
  command -v jq >/dev/null || skip "no jq"
  lockfile "$HOME/app"
  run vh lock_ext_reqs "$HOME/app"
  [ "$(echo "$output" | sort | tr '\n' ' ')" = "gd intl openssl pcntl zend-opcache " ]
}

@test "lock_ext_reqs copes with an empty platform list and no lock file" {
  command -v jq >/dev/null || skip "no jq"
  mkdir -p "$HOME/app"
  echo '{"packages": [{"name": "x", "require": {"ext-gd": "*"}}], "platform": []}' >"$HOME/app/composer.lock"
  [ "$(vh lock_ext_reqs "$HOME/app")" = gd ]
  [ -z "$(vh lock_ext_reqs "$HOME/nowhere")" ]
}

@test "missing_exts reports what the PHP lacks, matching names the way PHP spells them" {
  command -v jq >/dev/null || skip "no jq"
  lockfile "$HOME/app"
  # "Zend OPcache" is how php -m names ext-zend-opcache
  run missing "$HOME/app" 'core\nopenssl\nintl\npcntl\nzend opcache'
  [ "$output" = "$(printf 'gd\trequired by composer.lock')" ]
}

@test "declared extensions are checked too, and each is reported once" {
  command -v jq >/dev/null || skip "no jq"
  lockfile "$HOME/app"
  run vh eval 'php_bin_for() { echo /bin/true; }; PHP_MODULES_8_4="$(printf "openssl\nintl\npcntl\nzend opcache")"; SITE_EXT="protobuf gd"; missing_exts "'"$HOME/app"'" 8.4'
  [ "$output" = "$(printf 'gd\trequired by composer.lock\nprotobuf\tdeclared for this site')" ]
}

@test "with no PHP to check against, nothing is reported missing, and the reason is given" {
  lockfile "$HOME/app"
  run vh eval 'php_bin_for() { :; }; missing_exts "'"$HOME/app"'" 8.4'
  [ -z "$output" ]
  run vh eval 'php_bin_for() { :; }; ext_check_blocker "'"$HOME/app"'" 8.4'
  assert_contains "$output" "PHP 8.4"
}

@test "vhosty ext <site> shows that site's extensions" {
  run vh eval 'cmd_ext_list() { echo "listing $1"; }; cmd_ext escrow'
  [ "$output" = "listing escrow" ]
}
