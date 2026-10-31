#!/usr/bin/env bats
# vhosty services: what it needs before it touches anything

load helpers

@test "vhosty services says it needs jq, instead of failing halfway" {
  mkdir -p "$HOME/svc" "$HOME/nojq"
  write_config "VHOSTY_SERVICES_DIR=\"$HOME/svc\""
  # a PATH without jq
  for c in bash sed awk grep tr cut head tail uname id cat mkdir dirname; do ln -s "$(command -v "$c")" "$HOME/nojq/$c"; done
  run env PATH="$HOME/nojq" bash -c "source '$ROOT/bin/vhosty'; load_config; need_services"
  [ "$status" -ne 0 ]
  assert_contains "$output" "needs jq"
}

@test "a backup stops when it can't list the services, rather than saving just the config" {
  mkdir -p "$HOME/svc"
  write_config "VHOSTY_SERVICES_DIR=\"$HOME/svc\""
  stub docker 'case "$1" in info) exit 0 ;; compose) exit 1 ;; esac'
  run vh cmd_services_backup --to "$HOME/backups"
  [ "$status" -ne 0 ]
  assert_contains "$output" "Couldn't read the services"
  [ -z "$(ls -A "$HOME/backups" 2>/dev/null)" ]
}
