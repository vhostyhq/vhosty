#!/usr/bin/env bats
# Small helpers: names, versions, ini settings, finding tools

load helpers

@test "version_cmp orders versions numerically, ignoring v and suffixes" {
  [ "$(vh version_cmp v0.3.0 0.3.0)" = 0 ]
  [ "$(vh version_cmp v0.4.0 0.3.0)" = 1 ]
  [ "$(vh version_cmp 0.3.0 0.10.0)" = -1 ]
  [ "$(vh version_cmp 0.3 0.3.0)" = 0 ]
  [ "$(vh version_cmp 0.4.0-dev 0.4.0)" = 0 ]
  [ "$(vh version_cmp 1.0.0 0.99.99)" = 1 ]
}

@test "valid_name accepts hostname labels only" {
  vh valid_name escrow
  vh valid_name my-app2
  run vh valid_name -app;  [ "$status" -ne 0 ]
  run vh valid_name app-;  [ "$status" -ne 0 ]
  run vh valid_name MyApp; [ "$status" -ne 0 ]
  run vh valid_name my_app; [ "$status" -ne 0 ]
}

@test "name_from_folder turns a folder name into a hostname label" {
  [ "$(vh name_from_folder 'My App')" = my-app ]
  [ "$(vh name_from_folder '--Foo__Bar--')" = foo-bar ]
}

@test "ini_pairs reads key=value lines, skipping comments and sections" {
  printf '; comment\n[PHP]\nmemory_limit = -1\n  upload_max_filesize=1G  \n# also a comment\n' >"$HOME/php.ini"
  run vh ini_pairs "$HOME/php.ini"
  [ "$output" = "$(printf 'memory_limit=-1\nupload_max_filesize=1G')" ]
}

@test "ini_merge lets later keys win and keeps first-seen order" {
  run bash -c "printf 'a=1\nb=2\na=3\n' | { source '$ROOT/bin/vhosty'; ini_merge; }"
  [ "$output" = "$(printf 'a=3\nb=2')" ]
}

@test "sbin_cmd finds tools in /usr/sbin when they aren't on the PATH" {
  [ -x /usr/sbin/getcap ] || [ -x /sbin/getcap ] || skip "no getcap on this machine"
  run env PATH="$HOME/stubs:/usr/bin:/bin" bash -c "source '$ROOT/bin/vhosty'; sbin_cmd getcap"
  [ "$status" -eq 0 ]
  case "$output" in /usr/sbin/getcap|/sbin/getcap) ;; *) false ;; esac
  run vh sbin_cmd no-such-tool-here
  [ "$status" -ne 0 ]
}

@test "resolve_a uses dig when it's installed" {
  stub dig 'echo 100.64.0.7'
  [ "$(vh resolve_a anything.test.example)" = 100.64.0.7 ]
}

@test "resolve_a falls back to the system resolver without dig" {
  command -v getent >/dev/null || skip "no getent (macOS has dig)"
  # A PATH with the basics but no dig
  mkdir -p "$HOME/nodig"
  for c in bash getent awk tail head sed grep uname id; do ln -s "$(command -v "$c")" "$HOME/nodig/$c"; done
  run env PATH="$HOME/nodig" bash -c "source '$ROOT/bin/vhosty'; resolve_a localhost"
  [ "$status" -eq 0 ]
  [ "$output" = 127.0.0.1 ]
}

@test "cert_days_left counts the days until a certificate expires" {
  command -v openssl >/dev/null || skip "no openssl"
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout /dev/null \
    -subj "/CN=x" -days 30 -out "$HOME/c.crt" 2>/dev/null
  [ "$(vh cert_days_left "$HOME/c.crt")" = 30 ]
}

@test "temp paths with spaces are removed whole, and nothing else is" {
  mkdir -p "$HOME/Backups 2/services.partial" "$HOME/Backups" "$HOME/keep"
  touch "$HOME/Backups/precious"
  cd "$HOME"
  vh eval 'add_tmp "$HOME/Backups 2/services.partial"; add_tmp "$HOME/no such"; cleanup_tmp'
  [ ! -e "$HOME/Backups 2/services.partial" ]
  [ -f "$HOME/Backups/precious" ]
  [ -d "$HOME/keep" ]
}

@test "removing the last global PHP setting leaves an empty php.ini, not an error" {
  printf 'memory_limit = 1G\n' >"$VHOSTY_DIR/php.ini"
  run vh eval 'INI_SCOPE=global; ini_store ""'
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  run vh ini_pairs "$VHOSTY_DIR/php.ini"
  [ -z "$output" ]
  [ ! -e "$VHOSTY_DIR/php.ini.tmp" ]
}
