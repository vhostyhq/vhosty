#!/usr/bin/env bats
# Smaller fixes from the code review

load helpers

@test "only database images count as databases in a backup" {
  [ "$(vh service_kind mysql:8.4)" = mysql ]
  [ "$(vh service_kind mariadb:11)" = mysql ]
  [ "$(vh service_kind docker.io/library/postgres:18)" = postgres ]
  [ "$(vh service_kind pgvector/pgvector:pg18)" = postgres ]
  [ "$(vh service_kind bitnami/postgresql@sha256:abc)" = postgres ]
  [ "$(vh service_kind localhost:5000/mysql:8)" = mysql ]
  [ "$(vh service_kind prom/mysqld-exporter)" = volume ]
  [ "$(vh service_kind quay.io/prometheuscommunity/postgres-exporter)" = volume ]
  [ "$(vh service_kind valkey/valkey:8)" = volume ]
}

@test "linking over a parked site's name sets its settings aside, and unlink brings them back" {
  php_site escrow
  site_conf escrow "SITE_PATH=$PARKED/escrow
SITE_PHP=8.3
SITE_EXT=protobuf"
  mkdir -p "$HOME/Projects/escrow2"
  stub systemctl 'exit 0'
  vh eval 'cmd_rebuild() { :; }; cmd_link "$HOME/Projects/escrow2" --name escrow' >/dev/null
  conf="$(cat "$VHOSTY_DIR/sites/escrow.conf")"
  assert_contains "$conf" "SITE_LINKED=yes"
  refute_contains "$conf" "8.3"
  refute_contains "$conf" "protobuf"
  vh eval 'cmd_rebuild() { :; }; cmd_unlink escrow' >/dev/null
  conf="$(cat "$VHOSTY_DIR/sites/escrow.conf")"
  assert_contains "$conf" "SITE_PHP=8.3"
  assert_contains "$conf" "SITE_EXT=protobuf"
  [ ! -e "$VHOSTY_DIR/sites/escrow.conf.parked" ]
}

@test "prune counts a stale site's socket as a leftover right away" {
  php_site kudos
  site_conf kudos "SITE_PATH=$PARKED/kudos
SITE_INI='memory_limit=1G'"
  vh write_configs
  mkdir -p "$VHOSTY_DIR/run"; touch "$VHOSTY_DIR/run/site-kudos.sock" "$VHOSTY_DIR/run/site-old.sock"
  run vh prune_leftovers
  assert_contains "$output" "site-old.sock"
  refute_contains "$output" "site-kudos.sock"
  rm -rf "$PARKED/kudos"   # its folder is gone: its socket is a leftover now, not after a rebuild
  run vh prune_leftovers
  assert_contains "$output" "site-kudos.sock"
}

@test "vhosty sites flags folder names that can't be hostnames" {
  static_site good
  static_site my-app-
  static_site 5173
  run vh cmd_sites
  assert_contains "$output" "https://good.test.example"
  assert_contains "$output" "my-app- (not a valid hostname"
  assert_contains "$output" "5173 (a number"
  refute_contains "$output" "https://my-app-."
}
