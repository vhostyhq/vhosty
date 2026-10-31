#!/usr/bin/env bats
# DNS providers: Caddy's plugin and credentials, and the *.domain record

load helpers

@test "each provider has a plugin, a module, and Caddyfile lines" {
  for p in cloudflare digitalocean porkbun route53; do
    write_config "VHOSTY_DNS=$p"
    run vh eval 'dns_provider; echo "$DNS_MODULE $DNS_PLUGIN $DNS_MANAGED"'
    [ "$output" = "dns.providers.$p github.com/caddy-dns/$p $([ $p = cloudflare ] && echo yes || echo no)" ] || { echo "$p: $output" >&2; false; }
  done
}

@test "the Caddyfile gets the provider's lines in its tls block" {
  write_config 'VHOSTY_DNS=porkbun'
  vh write_caddyfile
  block="$(sed -n '/^\ttls {/,/^\t}/p' "$VHOSTY_DIR/Caddyfile")"
  assert_contains "$block" "		dns porkbun {"
  assert_contains "$block" "			api_key {env.PORKBUN_API_KEY}"
  refute_contains "$block" "cloudflare"
}

@test "a custom provider uses the plugin and line from the config" {
  write_config "VHOSTY_DNS=custom
VHOSTY_DNS_PLUGIN=github.com/caddy-dns/gandi
VHOSTY_DNS_TLS='dns gandi {env.GANDI_BEARER_TOKEN}'"
  run vh eval 'dns_provider; echo "$DNS_MODULE $DNS_PLUGIN"'
  [ "$output" = "dns.providers.gandi github.com/caddy-dns/gandi" ]
  vh write_caddyfile
  assert_contains "$(cat "$VHOSTY_DIR/Caddyfile")" "dns gandi {env.GANDI_BEARER_TOKEN}"
}

@test "an unknown provider, or custom without its settings, is refused" {
  write_config 'VHOSTY_DNS=nosuch'
  run vh write_caddyfile
  [ "$status" -ne 0 ]; assert_contains "$output" "isn't a provider vhosty knows"
  write_config 'VHOSTY_DNS=custom'
  run vh write_caddyfile
  [ "$status" -ne 0 ]; assert_contains "$output" "VHOSTY_DNS_PLUGIN"
}

@test "save_secret sets one credential and keeps the others, readable only by you" {
  printf 'CF_API_TOKEN=keep-me\nOTHER=x\n' >"$VHOSTY_DIR/.env"
  vh save_secret DO_AUTH_TOKEN dop1
  vh save_secret OTHER y
  [ "$(sort "$VHOSTY_DIR/.env" | tr '\n' ' ')" = "CF_API_TOKEN=keep-me DO_AUTH_TOKEN=dop1 OTHER=y " ]
  [ "$(ls -l "$VHOSTY_DIR/.env" | cut -c1-10)" = "-rw-------" ]
  [ "$(vh eval 'load_secret DO_AUTH_TOKEN; echo "$DO_AUTH_TOKEN"')" = dop1 ]
}

@test "for a provider vhosty doesn't manage, it shows the record to create" {
  write_config 'VHOSTY_DNS=porkbun'
  stub dig 'echo 203.0.113.5'
  run vh dns_point
  [ "$status" -eq 0 ]
  assert_contains "$output" "points to 203.0.113.5, not this machine (100.64.0.7)"
  assert_contains "$output" "*.test.example   A   100.64.0.7"
  stub dig 'echo 100.64.0.7'
  run vh dns_point
  assert_contains "$output" "*.test.example → 100.64.0.7"
}
