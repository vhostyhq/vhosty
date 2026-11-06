#!/usr/bin/env bats
# vhosty logs <site> and vhosty tail <site>: a site's own log, from its
# storage/logs. A service of the same name wins.

load helpers

setup() {
  vhosty_setup
  TAIL_PID=""
  mkdir -p "$VHOSTY_DIR/logs"
}

teardown() {
  if [ -n "$TAIL_PID" ]; then { kill -9 "$TAIL_PID"; wait "$TAIL_PID"; } 2>/dev/null || true; fi
  pkill -9 -f "^tail .*$HOME/" 2>/dev/null || true
}

# laravel_site NAME: a parked app with an empty storage/logs
laravel_site() {
  php_site "$1"
  mkdir -p "$PARKED/$1/storage/logs"
}

# write_lines FILE COUNT [WORD]: COUNT numbered lines
write_lines() {
  awk -v n="$2" -v w="${3:-line}" 'BEGIN { for (i = 1; i <= n; i++) print w, i }' >"$1"
}

# start_tail ARGS...: the real script in the background, as a command of its own
# so that $! is its process. fd 3 is closed or bats would wait for it.
start_tail() {
  "${VHOSTY_TEST_BASH:-bash}" "$ROOT/bin/vhosty" tail "$@" >"$HOME/out" 2>"$HOME/err" 3>&- &
  TAIL_PID=$!
}

# wait_for FILE TEXT: until the file has the text (10 seconds at most)
wait_for() {
  local i
  for i in $(seq 1 100); do
    if grep -qF -- "$2" "$1" 2>/dev/null; then return 0; fi
    sleep 0.1
  done
  printf 'never saw %s in %s:\n' "$2" "$1" >&2
  cat "$1" >&2
  return 1
}

# wait_gone PID: until the process has ended (10 seconds at most)
wait_gone() {
  local i
  for i in $(seq 1 100); do
    if ! kill -0 "$1" 2>/dev/null; then return 0; fi
    sleep 0.1
  done
  echo "process $1 is still running" >&2
  return 1
}

# tails_running: the tails left reading this test's folder
tails_running() { pgrep -f "^tail .*$HOME/" || true; }

# --- which file --------------------------------------------------------------

@test "the daily driver: the newest dated file" {
  laravel_site app
  logs="$PARKED/app/storage/logs"
  echo yesterday >"$logs/laravel-2026-11-04.log"
  touch -t 202611040900 "$logs/laravel-2026-11-04.log"
  echo today >"$logs/laravel-2026-11-05.log"
  [ "$(vh main logs app 2>/dev/null)" = "today" ]
}

@test "the single driver: laravel.log" {
  laravel_site app
  echo single >"$PARKED/app/storage/logs/laravel.log"
  [ "$(vh main logs app 2>/dev/null)" = "single" ]
}

@test "newest means last written, not last in the alphabet" {
  laravel_site app
  logs="$PARKED/app/storage/logs"
  echo worker >"$logs/worker.log"
  touch -t 202611040900 "$logs/worker.log"
  echo laravel >"$logs/laravel.log"
  [ "$(vh main logs app 2>/dev/null)" = "laravel" ]
}

@test "two logs as new as each other: the later name, so the later day" {
  laravel_site app
  logs="$PARKED/app/storage/logs"
  echo old >"$logs/laravel-2026-11-04.log"
  echo new >"$logs/laravel-2026-11-05.log"
  touch -t 202611050900 "$logs/laravel-2026-11-04.log" "$logs/laravel-2026-11-05.log"
  [ "$(vh main logs app 2>/dev/null)" = "new" ]
}

@test "only *.log counts: not rotated copies, or a folder named like a log" {
  laravel_site app
  logs="$PARKED/app/storage/logs"
  echo real >"$logs/laravel.log"
  touch -t 202611040900 "$logs/laravel.log"
  echo gz >"$logs/laravel.log.1.gz"
  mkdir "$logs/folder.log"
  [ "$(vh main logs app 2>/dev/null)" = "real" ]
}

@test "the file's path goes to stderr, not into a pipe" {
  laravel_site app
  echo hello >"$PARKED/app/storage/logs/laravel.log"
  run vh main logs app
  [ "$status" -eq 0 ]
  assert_contains "$output" "$PARKED/app/storage/logs/laravel.log"
  refute_contains "$(vh main logs app 2>/dev/null)" "storage/logs"
}

# --- N lines -----------------------------------------------------------------

@test "N lines, and 100 by default" {
  laravel_site app
  write_lines "$PARKED/app/storage/logs/laravel.log" 150
  out="$(vh main logs app 5 2>/dev/null)"
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = "5" ]
  [ "$(printf '%s\n' "$out" | sed -n 1p)" = "line 146" ]
  out="$(vh main logs app 2>/dev/null)"
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = "100" ]
  [ "$(printf '%s\n' "$out" | sed -n 1p)" = "line 51" ]
}

@test "N has to be a number" {
  laravel_site app
  echo hello >"$PARKED/app/storage/logs/laravel.log"
  run vh main logs app lots
  [ "$status" -eq 1 ]
  assert_contains "$output" "number of lines, not 'lots'"
}

# --- which sites -------------------------------------------------------------

@test "spaces in the site's path, for logs and tail" {
  dir="$HOME/My Projects/Escrow App"
  mkdir -p "$dir/storage/logs"
  site_conf escrow "SITE_PATH='$dir'
SITE_LINKED=yes"
  echo spaced >"$dir/storage/logs/my app.log"
  [ "$(vh main logs escrow 2>/dev/null)" = "spaced" ]

  start_tail escrow
  wait_for "$HOME/out" "spaced"
  echo more >>"$dir/storage/logs/my app.log"
  wait_for "$HOME/out" "more"
}

@test "a parked folder with capitals, by its site's name or its own" {
  mkdir -p "$PARKED/MyApp/storage/logs"
  echo capitals >"$PARKED/MyApp/storage/logs/laravel.log"
  [ "$(vh main logs myapp 2>/dev/null)" = "capitals" ]
  [ "$(vh main logs MyApp 2>/dev/null)" = "capitals" ]
}

@test "the log alias works, and so does follow" {
  laravel_site app
  echo aliased >"$PARKED/app/storage/logs/laravel.log"
  [ "$(vh main log app 2>/dev/null)" = "aliased" ]
  stub tail 'echo "tail $*"'
  run vh main follow app
  [ "$status" -eq 0 ]
  assert_contains "$output" "tail -n 30 -F $PARKED/app/storage/logs/laravel.log"
}

# --- a service wins ----------------------------------------------------------

@test "a site named like a service: the service wins, for logs" {
  laravel_site caddy
  echo from-site >"$PARKED/caddy/storage/logs/laravel.log"
  echo from-service >"$VHOSTY_DIR/logs/caddy.log"
  [ "$(vh main logs caddy)" = "from-service" ]
}

@test "a site named like a service: the service wins, for tail" {
  laravel_site caddy
  echo from-site >"$PARKED/caddy/storage/logs/laravel.log"
  echo from-service >"$VHOSTY_DIR/logs/caddy.log"
  stub tail 'echo "tail $*"'
  [ "$(vh main tail caddy)" = "tail -n 30 -f $VHOSTY_DIR/logs/caddy.log" ]
}

@test "the same goes for php, all, and a site's octane service" {
  laravel_site php
  laravel_site all
  laravel_site octane-app
  laravel_site app
  site_conf app "SITE_OCTANE=21000"
  for s in php all octane-app; do
    echo from-site >"$PARKED/$s/storage/logs/laravel.log"
  done
  echo fpm >"$(vh fpm_log 8.4)"
  echo octane >"$VHOSTY_DIR/logs/octane-app.log"
  refute_contains "$(vh main logs php 2>/dev/null)" "from-site"
  assert_contains "$(vh main logs php 2>/dev/null)" "fpm"
  refute_contains "$(vh main logs all 2>/dev/null)" "from-site"
  [ "$(vh main logs octane-app 2>/dev/null)" = "octane" ]
}

@test "a site named rotate: logs rotate still rotates" {
  laravel_site rotate
  echo from-site >"$PARKED/rotate/storage/logs/laravel.log"
  run vh main logs rotate
  [ "$status" -eq 0 ]
  assert_contains "$output" "nothing to rotate"
  refute_contains "$output" "from-site"
}

@test "a name that isn't a service right now can be a site's" {
  laravel_site octane-lab
  laravel_site php-8-app
  echo lab >"$PARKED/octane-lab/storage/logs/laravel.log"
  echo eight >"$PARKED/php-8-app/storage/logs/laravel.log"
  [ "$(vh main logs octane-lab 2>/dev/null)" = "lab" ]
  [ "$(vh main logs php-8-app 2>/dev/null)" = "eight" ]
}

# --- no argument, and services ------------------------------------------------

@test "logs with no argument: every service, and no site" {
  laravel_site app
  echo from-site >"$PARKED/app/storage/logs/laravel.log"
  echo from-caddy >"$VHOSTY_DIR/logs/caddy.log"
  fpm="$(vh fpm_log 8.4)"
  echo from-fpm >"$fpm"
  expected="$(tail -n 100 "$fpm" "$VHOSTY_DIR/logs/caddy.log")"
  [ "$(vh main logs)" = "$expected" ]
}

@test "tail with no argument: every service, with tail -f as ever" {
  laravel_site app
  echo from-site >"$PARKED/app/storage/logs/laravel.log"
  echo from-caddy >"$VHOSTY_DIR/logs/caddy.log"
  fpm="$(vh fpm_log 8.4)"
  echo from-fpm >"$fpm"
  stub tail 'echo "tail $*"'
  [ "$(vh main tail)" = "tail -n 30 -f $fpm $VHOSTY_DIR/logs/caddy.log" ]
}

@test "no argument and no log files: the same message as ever" {
  laravel_site app
  echo from-site >"$PARKED/app/storage/logs/laravel.log"
  run vh main logs
  [ "$status" -eq 1 ]
  assert_contains "$output" "No log files yet"
  refute_contains "$output" "from-site"
}

@test "a service's N lines still work" {
  write_lines "$VHOSTY_DIR/logs/caddy.log" 20
  [ "$(vh main logs caddy 3 | wc -l | tr -d ' ')" = "3" ]
}

@test "a service that can't be used keeps its own message" {
  run vh main logs php-9.9
  [ "$status" -eq 1 ]
  assert_contains "$output" "PHP 9.9 isn't installed"
  refute_contains "$output" "No service or site"

  run vh main logs octane
  [ "$status" -eq 1 ]
  assert_contains "$output" "No site runs on Octane"
  refute_contains "$output" "No service or site"
}

# --- when there's nothing to read ----------------------------------------------

@test "an unknown name lists what's valid" {
  laravel_site app
  static_site landing
  mkdir -p "$PARKED/not a hostname"
  linked="$HOME/elsewhere"
  mkdir -p "$linked"
  site_conf other "SITE_PATH='$linked'
SITE_LINKED=yes"
  site_conf gone "SITE_PATH='$HOME/no-such-folder'
SITE_LINKED=yes"
  run vh main logs nope
  [ "$status" -eq 1 ]
  assert_contains "$output" "No service or site 'nope'"
  assert_contains "$output" "Services: php-8.4 caddy (or all)"
  assert_contains "$output" "Sites: app landing other"
  refute_contains "$output" "gone"
  refute_contains "$output" "not a hostname"
  refute_contains "$output" "No log files yet"

  run vh main tail nope
  [ "$status" -eq 1 ]
  assert_contains "$output" "No service or site 'nope'"
}

@test "an unknown name, with no sites at all" {
  run vh main logs nope
  [ "$status" -eq 1 ]
  assert_contains "$output" "Sites: none"
}

@test "an unknown name, before setup" {
  rm "$VHOSTY_DIR/config"
  run vh main logs nope
  [ "$status" -eq 1 ]
  assert_contains "$output" "No service or site 'nope'"
}

@test "with the Herd backend, a site is an unknown name, with a clear message" {
  cat >"$VHOSTY_DIR/config" <<EOF
VHOSTY_DOMAIN="test.example"
VHOSTY_BACKEND="herd"
VHOSTY_PHP="off"
EOF
  run vh main logs escrow
  [ "$status" -eq 1 ]
  assert_contains "$output" "No service or site 'escrow'"
  echo from-caddy >"$VHOSTY_DIR/logs/caddy.log"
  [ "$(vh main logs caddy)" = "from-caddy" ]
}

@test "a name with a slash isn't a path out of the sites folder" {
  mkdir -p "$HOME/outside"
  echo 'touch "$HOME/sourced"' >"$HOME/outside/evil.conf"
  run vh main logs ../../outside/evil
  [ "$status" -eq 1 ]
  assert_contains "$output" "No service or site '../../outside/evil'"
  [ ! -e "$HOME/sourced" ]
}

@test "a site with no storage/logs says so" {
  static_site landing
  run vh main logs landing
  [ "$status" -eq 1 ]
  assert_contains "$output" "'landing' has no storage/logs ($PARKED/landing)"

  run vh main tail landing
  [ "$status" -eq 1 ]
  assert_contains "$output" "'landing' has no storage/logs"
}

@test "a site with no log files yet says so" {
  laravel_site app
  run vh main logs app
  [ "$status" -eq 1 ]
  assert_contains "$output" "No log files yet in $PARKED/app/storage/logs"

  run vh main tail app
  [ "$status" -eq 1 ]
  assert_contains "$output" "No log files yet in $PARKED/app/storage/logs"
}

@test "a link whose folder is gone says so" {
  site_conf gone "SITE_PATH='$HOME/no-such-folder'
SITE_LINKED=yes"
  run vh main logs gone
  [ "$status" -eq 1 ]
  assert_contains "$output" "The folder for 'gone' is gone"
  assert_contains "$output" "vhosty prune"
}

@test "a config whose folder isn't parked any more says so" {
  site_conf old "SITE_PHP=8.4"
  run vh main logs old
  [ "$status" -eq 1 ]
  assert_contains "$output" "No folder for 'old'"
}

# --- pipes --------------------------------------------------------------------

@test "logs into a reader that stops early: quiet, and no failure" {
  laravel_site app
  write_lines "$PARKED/app/storage/logs/laravel.log" 200000
  script="\"\${VHOSTY_TEST_BASH:-bash}\" \"$ROOT/bin/vhosty\" logs app 200000 2>\"$HOME/err\" | { read -r _; }; echo \"\${PIPESTATUS[0]}\""
  [ "$(bash -c "$script")" = "0" ]
  err="$(cat "$HOME/err")"
  refute_contains "$err" "Broken pipe"
  refute_contains "$err" "write error"
  refute_contains "$err" "error:"
}

@test "tail into a reader that stops early ends quietly, and leaves no tail" {
  laravel_site app
  log="$PARKED/app/storage/logs/laravel.log"
  write_lines "$log" 3
  ( "${VHOSTY_TEST_BASH:-bash}" "$ROOT/bin/vhosty" tail app 2>"$HOME/err" 3>&-; echo $? >"$HOME/rc" ) | { read -r _; } &
  TAIL_PID=$!
  # A write after the reader has gone is what ends tail
  for _ in $(seq 1 100); do
    [ ! -f "$HOME/rc" ] || break
    echo more >>"$log"
    sleep 0.1
  done
  [ "$(cat "$HOME/rc")" = "0" ]
  [ -z "$(tails_running)" ]
  err="$(cat "$HOME/err")"
  refute_contains "$err" "Broken pipe"
  refute_contains "$err" "write error"
  refute_contains "$err" "Terminated"
}

# --- tail ---------------------------------------------------------------------

@test "tail: the last 30 lines, then new ones" {
  laravel_site app
  log="$PARKED/app/storage/logs/laravel.log"
  write_lines "$log" 40
  start_tail app
  wait_for "$HOME/out" "line 40"
  refute_contains "$(cat "$HOME/out")" "line 10"$'\n'
  assert_contains "$(cat "$HOME/out")" "line 11"
  echo fresh >>"$log"
  wait_for "$HOME/out" "fresh"
  assert_contains "$(cat "$HOME/err")" "$log"
}

@test "tail goes on to the next day's file when the date rolls over" {
  laravel_site app
  logs="$PARKED/app/storage/logs"
  echo day-one >"$logs/laravel-2026-11-05.log"
  start_tail app
  wait_for "$HOME/out" "day-one"

  # The last of the old day, then the first of the new
  echo late-day-one >>"$logs/laravel-2026-11-05.log"
  printf 'day-two a\nday-two b\n' >"$logs/laravel-2026-11-06.log"
  wait_for "$HOME/out" "day-two b"
  assert_contains "$(cat "$HOME/out")" "late-day-one"
  assert_contains "$(cat "$HOME/out")" "day-two a"
  assert_contains "$(cat "$HOME/err")" "laravel-2026-11-06.log"

  # On the new file, and the old tail has been stopped
  echo day-two-c >>"$logs/laravel-2026-11-06.log"
  wait_for "$HOME/out" "day-two-c"
  running="$(pgrep -f "^tail .*laravel-2026-11-05" || true)"
  [ -z "$running" ]
  refute_contains "$(cat "$HOME/err")" "Terminated"
}

@test "tail stays on its file when another log in the folder is written" {
  laravel_site app
  logs="$PARKED/app/storage/logs"
  echo main-log >"$logs/laravel.log"
  start_tail app
  wait_for "$HOME/out" "main-log"
  echo other >"$logs/worker.log"
  echo other >"$logs/worker-2026-11-06.log"
  echo other >"$logs/laravel-2026-11-06.log"
  sleep 3
  echo still-here >>"$logs/laravel.log"
  wait_for "$HOME/out" "still-here"
  refute_contains "$(cat "$HOME/out")" "other"
}

@test "tail: ending it ends its tail too, with no noise" {
  laravel_site app
  echo hello >"$PARKED/app/storage/logs/laravel.log"
  start_tail app
  wait_for "$HOME/out" "hello"
  [ -n "$(tails_running)" ]
  kill "$TAIL_PID"
  wait_gone "$TAIL_PID"
  [ -z "$(tails_running)" ]
  refute_contains "$(cat "$HOME/err")" "Terminated"
}

@test "tail: Ctrl-C ends its tail too" {
  command -v python3 >/dev/null || skip "needs python3"
  laravel_site app
  echo hello >"$PARKED/app/storage/logs/laravel.log"
  # A background job starts with SIGINT ignored, and a shell can't trap what it
  # started with ignored, so this puts SIGINT back first, as in a terminal
  python3 -c 'import os, signal, sys; signal.signal(signal.SIGINT, signal.SIG_DFL); os.execvp(sys.argv[1], sys.argv[1:])' \
    "${VHOSTY_TEST_BASH:-bash}" "$ROOT/bin/vhosty" tail app >"$HOME/out" 2>"$HOME/err" 3>&- &
  TAIL_PID=$!
  wait_for "$HOME/out" "hello"
  [ -n "$(tails_running)" ]
  kill -INT "$TAIL_PID"
  wait_gone "$TAIL_PID"
  [ -z "$(tails_running)" ]
}

# --- the next file -------------------------------------------------------------

@test "the next file: the next day there is, in the same series" {
  logs="$HOME/a [b] folder/storage/logs"
  mkdir -p "$logs"
  touch "$logs/laravel-2026-11-05.log" "$logs/laravel-2026-11-08.log" "$logs/laravel-2026-11-09.log"
  touch "$logs/worker-2026-11-07.log" "$logs/laravel-extra-2026-11-06.log" "$logs/laravel.log"
  [ "$(vh site_log_after "$logs/laravel-2026-11-05.log")" = "$logs/laravel-2026-11-08.log" ]
  [ "$(vh site_log_after "$logs/laravel-2026-11-08.log")" = "$logs/laravel-2026-11-09.log" ]
  [ -z "$(vh site_log_after "$logs/laravel-2026-11-09.log")" ]
  [ -z "$(vh site_log_after "$logs/laravel-extra-2026-11-06.log")" ]
  [ -z "$(vh site_log_after "$logs/laravel.log")" ]
}

# --- completion ----------------------------------------------------------------

@test "completion offers sites as well as services, for logs and tail" {
  command -v zsh >/dev/null || skip "needs zsh"
  cat >"$HOME/complete.zsh" <<EOF
_alternative() { print -r -- "\$@"; }
words=(vhosty "\$1" ''); CURRENT=3
source "$ROOT/completions/_vhosty"
EOF
  logs="$(zsh "$HOME/complete.zsh" logs)"
  assert_contains "$logs" "sites:site:_vhosty_sites"
  assert_contains "$logs" "services:service:_vhosty_services"
  assert_contains "$logs" "actions:action:(rotate)"
  tail="$(zsh "$HOME/complete.zsh" tail)"
  assert_contains "$tail" "sites:site:_vhosty_sites"
  assert_contains "$tail" "services:service:_vhosty_services"
}
