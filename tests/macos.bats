#!/usr/bin/env bats
# vhosty's own mode on macOS: PHP from Homebrew, and log rotation from launchd
# (Caddy is behind Tailscale Serve there as everywhere: serve.bats). Runs
# anywhere: `mac` runs one of vhosty's functions as if on macOS, with a fake
# Homebrew (shell scripts standing in for its PHP binaries, and a brew that
# logs what it's asked).

load helpers

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
