#!/usr/bin/env bats
# What answers names that aren't a port or a proxy: vhosty's own sites
# (VHOSTY_SITES=on), another server (VHOSTY_FORWARD, see forward.bats), or
# nothing, when vhosty is only the gateway. And vhosty enable / disable.

load helpers

gateway() { write_config "VHOSTY_SITES=\"off\"
${1:-}"; }
proxy_to() { mkdir -p "$VHOSTY_DIR/proxies"; printf 'PROXY_PORT=%s\n' "$2" >"$VHOSTY_DIR/proxies/$1.conf"; }

@test "an older config, without VHOSTY_SITES, keeps serving its folders" {
  php_site shop
  run vh fallback_mode
  [ "$output" = sites ]
  vh write_configs
  assert_contains "$(cat "$VHOSTY_DIR/Caddyfile")" "php_fastcgi"
  run vh main rebuild
  assert_contains "$output" "added VHOSTY_SITES=on"
  assert_contains "$(cat "$VHOSTY_DIR/config")" "VHOSTY_SITES=on"
  run vh main rebuild
  refute_contains "$output" "VHOSTY_SITES"
}

@test "a new machine, with no config yet, starts as the gateway only" {
  rm "$VHOSTY_DIR/config"
  run vh fallback_mode
  [ "$output" = none ]
}

@test "forwarding wins over sites, as both would answer every name" {
  write_config 'VHOSTY_SITES="on"
VHOSTY_FORWARD="test"'
  run vh fallback_mode
  [ "$output" = forward ]
  refute vh php_enabled
}

@test "the gateway only: proxies, then the no-site page; no folders, no PHP" {
  gateway
  php_site shop
  proxy_to jellyfin 8096
  vh write_configs
  caddyfile="$(cat "$VHOSTY_DIR/Caddyfile")"
  assert_contains "$caddyfile" "reverse_proxy localhost:8096"
  assert_contains "$caddyfile" "vhosty_kind nosite"
  assert_contains "$caddyfile" "vhosty_mode none"
  assert_contains "$caddyfile" 'vhosty_parked ""'
  assert_contains "$caddyfile" 'vhosty_sites "jellyfin"'
  refute_contains "$caddyfile" "php_fastcgi"
  refute_contains "$caddyfile" "$PARKED"
  run vh svc_all
  [ "$output" = caddy ]
  [ ! -e "$VHOSTY_DIR/bin/php" ]
}

@test "the gateway only: commands for sites say how to turn them on; proxies work" {
  gateway
  for c in park link "site shop" "isolate 8.4" "ini set memory_limit 1G" "worktree list" "octane list"; do
    # shellcheck disable=SC2086
    run vh main $c
    [ "$status" -ne 0 ] || { echo "$c worked" >&2; false; }
    assert_contains "$output" "only proxies and ports. To serve folders and PHP: vhosty enable sites"
  done
  run vh main proxy jellyfin 8096
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  run vh main sites
  assert_contains "$output" "https://jellyfin.test.example"
}

@test "the gateway only: vhosty sites with nothing yet says how to add a name" {
  gateway
  run vh main sites
  [ "$status" -ne 0 ]
  assert_contains "$output" "vhosty proxy <name> <port>"
}

@test "the gateway only: a proxy can take a parked folder's name, as nothing serves it" {
  gateway
  php_site shop
  run vh fallback_owner shop
  [ "$status" -ne 0 ]
  run vh main proxy shop 3000
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
}

@test "who answers a name: a port, then a proxy, then a site" {
  php_site shop
  run vh name_owner 5173
  [ "$output" = port ]
  run vh name_owner shop
  [ "$output" = "site (parked in $PARKED)" ]
  proxy_to grafana 3001
  run vh name_owner grafana
  [ "$output" = proxy ]
  run vh name_owner nothing
  [ "$status" -ne 0 ]
}

@test "the mode line says what the machine does" {
  gateway 'VHOSTY_PORTS=""'
  run vh mode_line
  [ "$output" = "gateway" ]
  write_config 'VHOSTY_SERVICES_DIR="/srv/services"'
  run vh mode_line
  [ "$output" = "gateway · sites (PHP) · ports · services" ]
  write_config 'VHOSTY_PHP="off"
VHOSTY_PORTS=""'
  run vh mode_line
  [ "$output" = "gateway · sites (static)" ]
}

@test "enable sites parks a folder; disable sites keeps it for next time" {
  gateway
  mkdir -p "$HOME/Code/blog"; echo '<h1>hi</h1>' >"$HOME/Code/blog/index.html"
  run vh main enable sites --park "$HOME/Code" --no-php
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  run vh fallback_mode
  [ "$output" = sites ]
  assert_contains "$(cat "$VHOSTY_DIR/config")" "$HOME/Code"
  assert_contains "$(cat "$VHOSTY_DIR/Caddyfile")" "$HOME/Code/{labels.2}"
  run vh main disable sites
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  run vh fallback_mode
  [ "$output" = none ]
  assert_contains "$(cat "$VHOSTY_DIR/config")" "$HOME/Code"
  refute_contains "$(cat "$VHOSTY_DIR/Caddyfile")" "$HOME/Code"
}

@test "enable forward turns sites off, says all of its settings, and enable sites turns it off" {
  run vh main enable forward test --tld dev --http 127.0.0.1:8080
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  assert_contains "$output" "vhosty's own sites stop"
  config="$(cat "$VHOSTY_DIR/config")"
  assert_contains "$config" "VHOSTY_SITES=off"
  assert_contains "$config" "VHOSTY_FORWARD=test"
  assert_contains "$config" "VHOSTY_FORWARD_TLD=dev"
  assert_contains "$(cat "$VHOSTY_DIR/Caddyfile")" "reverse_proxy http://127.0.0.1:8080"
  run vh main enable forward test
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  refute_contains "$(cat "$VHOSTY_DIR/config")" "VHOSTY_FORWARD_TLD=dev"
  run vh main enable sites --no-php
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  assert_contains "$output" "Forwarding to the web server on this machine stops"
  run vh fallback_mode
  [ "$output" = sites ]
}

@test "enable forward refuses a preset whose server isn't set up" {
  export VHOSTY_HERD_DIR="$HOME/no-herd"
  run vh main enable forward herd
  [ "$status" -ne 0 ]
  assert_contains "$output" "Herd isn't set up here"
  run vh fallback_mode
  [ "$output" = sites ]
}

@test "enable ports opens the dev servers' ports; disable ports closes them" {
  gateway 'VHOSTY_PORTS=""'
  refute_contains "$(vh write_configs; cat "$VHOSTY_DIR/Caddyfile")" "{re.port.1}"
  run vh main enable ports
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  assert_contains "$(cat "$VHOSTY_DIR/config")" "VHOSTY_PORTS=3000-5999"
  assert_contains "$(cat "$VHOSTY_DIR/Caddyfile")" "{re.port.1}"
  run vh main enable ports "9000-9001"
  assert_contains "$(cat "$VHOSTY_DIR/config")" 'VHOSTY_PORTS=9000-9001'
  run vh main enable ports "nope"
  [ "$status" -ne 0 ]
  run vh main disable ports
  [ "$status" -eq 0 ]
  refute_contains "$(cat "$VHOSTY_DIR/Caddyfile")" "{re.port.1}"
}

@test "disable services stops them and forgets the folder; compose.yaml and data stay" {
  mkdir -p "$HOME/services"; echo 'services: {}' >"$HOME/services/compose.yaml"
  write_config "VHOSTY_SERVICES_DIR=\"$HOME/services\""
  stub docker 'echo "docker $*" >>"$HOME/docker.log"; exit 0'
  run vh main disable services
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  assert_contains "$(cat "$HOME/docker.log")" "compose --project-directory $HOME/services down"
  refute_contains "$(cat "$HOME/docker.log")" "down -v"
  assert_contains "$output" "vhosty enable services --dir $HOME/services"
  assert_contains "$(cat "$VHOSTY_DIR/config")" "VHOSTY_SERVICES_DIR=''"
  [ -f "$HOME/services/compose.yaml" ]
}

@test "disable sites or forward again rebuilds, so a retry finishes what a failed rebuild left" {
  gateway
  rm -f "$VHOSTY_DIR/Caddyfile"
  run vh main disable sites
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  assert_contains "$output" "isn't serving sites here"
  [ -f "$VHOSTY_DIR/Caddyfile" ]
  rm -f "$VHOSTY_DIR/Caddyfile"
  run vh main disable forward
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [ -f "$VHOSTY_DIR/Caddyfile" ]
}

@test "enable ports with an empty list is refused, not read as the defaults" {
  gateway 'VHOSTY_PORTS=""'
  run vh main enable ports ""
  [ "$status" -ne 0 ]
  assert_contains "$output" "No ports given"
  assert_contains "$(cat "$VHOSTY_DIR/config")" 'VHOSTY_PORTS=""'
}

@test "setup refuses flags for two different setups, in either order" {
  for flags in "--gateway --park $HOME/New" "--park $HOME/New --gateway" "--forward herd --park $HOME/New" \
    "--sites --forward test" "--gateway --herd"; do
    # shellcheck disable=SC2086
    run vh main setup $flags
    [ "$status" -ne 0 ] || { echo "accepted: $flags" >&2; false; }
    assert_contains "$output" "--"
  done
  [ ! -d "$HOME/New" ]
}

@test "enable sites refuses a parked folder whose full path vhosty can't use" {
  gateway
  mkdir -p "$HOME/a:b/blog"
  cd "$HOME/a:b"
  run vh main enable sites --park . --no-php
  [ "$status" -ne 0 ]
  assert_contains "$output" "has a colon"
  refute_contains "$(cat "$VHOSTY_DIR/config")" "a:b"
}

@test "enable and disable say what they take" {
  run vh main enable
  [ "$status" -ne 0 ]
  assert_contains "$output" "vhosty enable forward <herd|valet|lerd|TLD>"
  run vh main disable nothing
  [ "$status" -ne 0 ]
  assert_contains "$output" "vhosty disable sites | forward | services | ports"
}
