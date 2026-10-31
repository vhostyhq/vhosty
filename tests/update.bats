#!/usr/bin/env bats
# vhosty update self: checksums, and never leaving a half-installed vhosty

load helpers

setup() {
  vhosty_setup
  # A fake GitHub: curl serves files from $HOME/srv/<host>/<path>
  stub curl '
out="" url=""
while [ $# -gt 0 ]; do
  case "$1" in -o) out="$2"; shift 2 ;; http*) url="$1"; shift ;; *) shift ;; esac
done
f="$HOME/srv/${url#https://}"
[ -f "$f" ] || exit 22
if [ -n "$out" ]; then cp "$f" "$out"; else cat "$f"; fi'
  # The installed vhosty, and release v9.9.9
  mkdir -p "$VHOSTY_DIR/bin"
  echo "old" >"$VHOSTY_DIR/bin/vhosty"
  REL="$HOME/srv/raw.githubusercontent.com/vhostyhq/vhosty/v9.9.9"
  mkdir -p "$REL/bin" "$REL/completions"
  sed 's/^VHOSTY_VERSION=.*/VHOSTY_VERSION="9.9.9"/' "$ROOT/bin/vhosty" >"$REL/bin/vhosty"
  cp "$ROOT/completions/_vhosty" "$REL/completions/_vhosty"
  SUMS="$HOME/srv/github.com/vhostyhq/vhosty/releases/download/v9.9.9/SHA256SUMS"
  mkdir -p "${SUMS%/*}"
}

sum() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }

publish_sums() {
  printf '%s  vhosty\n%s  _vhosty\n' "$(sum "$REL/bin/vhosty")" "$(sum "$REL/completions/_vhosty")" >"$SUMS"
}

installed_version() { sed -n 's/^VHOSTY_VERSION="\(.*\)"$/\1/p' "$VHOSTY_DIR/bin/vhosty"; }

@test "a release whose checksums match is installed" {
  publish_sums
  run vh cmd_update_self --ref v9.9.9 --force
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [ "$(installed_version)" = 9.9.9 ]
  [ -f "$VHOSTY_DIR/completions/_vhosty" ]
}

@test "a download that doesn't match its checksum isn't installed, and nothing is left behind" {
  publish_sums
  echo "# tampered" >>"$REL/bin/vhosty"
  run vh cmd_update_self --ref v9.9.9 --force
  [ "$status" -ne 0 ]
  assert_contains "$output" "doesn't match its published checksum"
  [ "$(cat "$VHOSTY_DIR/bin/vhosty")" = old ]
  [ ! -e "$VHOSTY_DIR/bin/.vhosty.new" ]
}

@test "a release without checksums still installs, saying so" {
  run vh cmd_update_self --ref v9.9.9 --force
  [ "$status" -eq 0 ]
  assert_contains "$output" "no checksums published with v9.9.9"
  [ "$(installed_version)" = 9.9.9 ]
}

@test "something that isn't vhosty is never installed" {
  echo "<html>not found</html>" >"$REL/bin/vhosty"
  run vh cmd_update_self --ref v9.9.9 --force
  [ "$status" -ne 0 ]
  [ "$(cat "$VHOSTY_DIR/bin/vhosty")" = old ]
}

@test "doctor's release check asks GitHub at most once a day" {
  stub curl 'echo x >>"$HOME/curl.calls"; printf "https://github.com/vhostyhq/vhosty/releases/tag/v9.9.9"'
  [ "$(vh latest_release_cached)" = v9.9.9 ]
  [ "$(vh latest_release_cached)" = v9.9.9 ]
  [ "$(wc -l <"$HOME/curl.calls" | tr -d ' ')" = 1 ]
  touch -t 202001010000 "$VHOSTY_DIR/run/latest-release"   # a stale answer is asked again
  vh latest_release_cached >/dev/null
  [ "$(wc -l <"$HOME/curl.calls" | tr -d ' ')" = 2 ]
}
