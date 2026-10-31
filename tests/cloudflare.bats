#!/usr/bin/env bats
# Cloudflare: the token stays off command lines, and --yes leaves other people's records alone

load helpers

# A fake curl that answers like Cloudflare's API, records its arguments and
# the config it reads on stdin, and notes record updates
fake_cloudflare() { # fake_cloudflare CURRENT-RECORD-IP
  stub curl "
printf '%s\n' \"\$*\" >>'$HOME/curl.args'
[ -t 0 ] || cat >>'$HOME/curl.stdin'
case \"\$*\" in
  *'zones?name='*) echo '{\"success\":true,\"result\":[{\"id\":\"zone1\"}]}' ;;
  *'dns_records?type=A'*) echo '{\"success\":true,\"result\":[{\"id\":\"rec1\",\"content\":\"$1\",\"proxied\":false}]}' ;;
  *'-X PUT'*) touch '$HOME/updated'; echo '{\"success\":true,\"result\":{}}' ;;
  *) echo '{\"success\":true,\"result\":{}}' ;;
esac"
  printf 'CF_API_TOKEN=secret-token-123\n' >"$VHOSTY_DIR/.env"
}

@test "the Cloudflare token goes to curl on stdin, never in its arguments" {
  command -v jq >/dev/null || skip "no jq"
  fake_cloudflare 100.64.0.9
  vh dns_sync
  [ -f "$HOME/updated" ]
  ! grep -q secret-token-123 "$HOME/curl.args"
  grep -q 'Authorization: Bearer secret-token-123' "$HOME/curl.stdin"
}

@test "--yes doesn't replace a record that isn't a Tailscale address" {
  command -v jq >/dev/null || skip "no jq"
  fake_cloudflare 203.0.113.10
  run env VHOSTY_YES=1 bash -c "source '$ROOT/bin/vhosty'; load_config; dns_sync"
  [ "$status" -ne 0 ]
  assert_contains "$output" "--overwrite-dns"
  [ ! -f "$HOME/updated" ]
}

@test "--overwrite-dns does replace it" {
  command -v jq >/dev/null || skip "no jq"
  fake_cloudflare 203.0.113.10
  run env VHOSTY_YES=1 VHOSTY_OVERWRITE_DNS=1 bash -c "source '$ROOT/bin/vhosty'; load_config; dns_sync"
  [ "$status" -eq 0 ]
  [ -f "$HOME/updated" ]
}

@test "a record already pointing at another Tailscale address is updated with --yes" {
  command -v jq >/dev/null || skip "no jq"
  fake_cloudflare 100.64.0.9
  run env VHOSTY_YES=1 bash -c "source '$ROOT/bin/vhosty'; load_config; dns_sync"
  [ "$status" -eq 0 ]
  [ -f "$HOME/updated" ]
}
