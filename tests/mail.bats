#!/usr/bin/env bats
# vhosty mail: Mailpit in compose.yaml, and what it prints. No containers start:
# docker is a stub, except for the tests that ask the real compose to read a file
# (config only), which are skipped without it.

load helpers

# Found before vhosty_setup puts the stubs first on the PATH
REAL_DOCKER="$(command -v docker || true)"

setup() {
  vhosty_setup
  SVC="$HOME/svc"
  mkdir -p "$SVC"
  stub_docker
}

# Every docker call goes to the log. compose config answers from $HOME/config.json.
stub_docker() {
  stub docker '
echo "docker $*" >>"$HOME/docker.log"
case "$1" in
  info) [ $# -gt 1 ] && echo 8589934592; exit 0 ;;
  compose)
    case "$*" in
      # With -f: is Mailpit in that file (the check mail add makes of its result)
      *" -f "*" config --services"*)
        while [ "$1" != "-f" ]; do shift; done
        if grep -q "^ *mailpit:" "$2"; then echo mailpit; fi ;;
      *" config --services"*) jq -r ".services | keys[]" "$HOME/config.json" ;;
      *" config"*) cat "$HOME/config.json" ;;
      *" ps "*) cat "$HOME/ps.json" 2>/dev/null ;;
    esac ;;
esac
exit 0'
  echo '{"services":{}}' >"$HOME/config.json"
}

# The stub, for docker compose config only, hands over to real compose
real_compose_config() {
  [ -n "$REAL_DOCKER" ] && "$REAL_DOCKER" compose version >/dev/null 2>&1 || skip "no docker compose"
  stub docker "
echo \"docker \$*\" >>\"\$HOME/docker.log\"
case \"\$1 \$*\" in
  compose*' config'*) exec \"$REAL_DOCKER\" \"\$@\" ;;
  info*) [ \$# -gt 1 ] && echo 8589934592; exit 0 ;;
esac
exit 0"
}

# A compose file that has been lived in: comments, odd spacing, hand edits
lived_in() {
  cat >"$SVC/compose.yaml" <<'YAML'
# My services. Don't lose this comment.
name: my-stack

x-common: &common
  restart: always # hand edit

services:
  # the database
  mysql:
    <<: *common
    image: mysql:8.0   # pinned on purpose
    ports: ["127.0.0.1:3307:3306"]
    volumes: [mysql:/var/lib/mysql]
    depends_on:
      valkey:
        condition: service_started

# col-0 comment inside services
  valkey:
    image: valkey/valkey:9-alpine
    command: |
      valkey-server
        --save 60 1
  # redis:
  #   image: redis:7

# Named volumes, keep this comment with them
volumes:
  mysql:
    name: precious_mysql
  # old: gone
networks:
  default:
    name: my-net
YAML
}

use_svc() { write_config "VHOSTY_SERVICES_DIR=\"$SVC\"
${1:-}"; }

# Every line of $1 is still in $2, in order: only additions in the diff
only_added() {
  run diff "$1" "$2"
  [ "$status" -eq 1 ] || { echo "no difference: $output" >&2; false; }
  if printf '%s\n' "$output" | grep -E '^(<|[0-9,]+[cd][0-9,]*$)'; then
    echo "lines changed or removed: $output" >&2
    false
  fi
}

mailpit_config() {
  echo '{"services":{"mailpit":{"image":"axllent/mailpit:v1.33","ports":[{"target":1025,"published":"'"${1:-1025}"'"},{"target":8025,"published":"'"${2:-8025}"'"}]}}}' >"$HOME/config.json"
}

# ---- services init ----

@test "init without --only includes Mailpit" {
  run vh cmd_services_init "$SVC"
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  f="$(cat "$SVC/compose.yaml")"
  assert_contains "$f" "  mysql:"
  assert_contains "$f" "  mailpit:"
  assert_contains "$f" "image: axllent/mailpit:v1.33"
  assert_contains "$f" '"127.0.0.1:1025:1025"'
  assert_contains "$f" '"127.0.0.1:8025:8025"'
  assert_contains "$f" "[mailpit:/data]"
  assert_contains "$f" "MP_DATABASE: /data/mailpit.db"
  [ "$(sed -n '/^volumes:/,$p' "$SVC/compose.yaml" | grep -c '^  mailpit:$')" = 1 ]
}

@test "init --only mailpit writes just Mailpit, and --only without it leaves it out" {
  run vh cmd_services_init "$SVC" --only mailpit
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [ "$(grep -c '^  [a-z]*:$' "$SVC/compose.yaml")" = 2 ]   # the service and its volume
  assert_contains "$output" "vhosty mail"
  # Needs no keys
  [ ! -s "$SVC/.env" ]

  run vh cmd_services_init "$HOME/other" --only mysql,valkey
  [ "$status" -eq 0 ]
  refute_contains "$(cat "$HOME/other/compose.yaml")" "mailpit"
  refute_contains "$output" "vhosty mail"
}

@test "init on an existing file still refuses, and points at mail add" {
  lived_in
  before="$(cat "$SVC/compose.yaml")"
  run vh cmd_services_init "$SVC" --only mailpit
  [ "$status" -ne 0 ]
  assert_contains "$output" "already exists"
  assert_contains "$output" "vhosty mail add"
  [ "$(cat "$SVC/compose.yaml")" = "$before" ]
}

@test "the file init writes is valid compose, with Mailpit bound to localhost" {
  real_compose_config
  run vh cmd_services_init "$SVC"
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  run "$REAL_DOCKER" compose --project-directory "$SVC" config --format json
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  json="$output"
  [ "$(echo "$json" | jq -r '.services.mailpit.ports | map("\(.host_ip):\(.published)->\(.target)") | sort | join(" ")')" = "127.0.0.1:1025->1025 127.0.0.1:8025->8025" ]
  [ "$(echo "$json" | jq -r '.services.mailpit.volumes[0] | "\(.type) \(.source) \(.target)"')" = "volume mailpit /data" ]
  [ "$(echo "$json" | jq -r '.services.mailpit.healthcheck.test | join(" ")')" = "CMD /mailpit readyz" ]
  [ "$(echo "$json" | jq -r '.services.mailpit.environment.MP_DATABASE')" = "/data/mailpit.db" ]
  [ "$(echo "$json" | jq -r '.volumes | has("mailpit")')" = true ]
}

# ---- mail add ----

@test "mail add keeps comments and hand edits, and adds only Mailpit" {
  lived_in
  use_svc
  cp "$SVC/compose.yaml" "$HOME/orig.yaml"
  run vh cmd_mail add
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  only_added "$HOME/orig.yaml" "$SVC/compose.yaml"
  assert_contains "$(cat "$SVC/compose.yaml")" "image: axllent/mailpit:v1.33"
  # A backup, byte for byte, and no temp file left
  bak="$(ls "$SVC"/compose.yaml.before-mailpit-*)"
  cmp "$bak" "$HOME/orig.yaml"
  ls -a "$SVC" >"$HOME/ls.out"
  run grep -c vhosty-new "$HOME/ls.out"
  [ "$output" = 0 ]
  # In the two sections: the service before the col-0 volumes comment, the volume before networks
  awk '/^  mailpit:$/ { n++; line[n] = NR } /^# Named volumes/ { c = NR } /^volumes:/ { v = NR } /^networks:/ { w = NR }
       END { exit !(n == 2 && line[1] < c && line[2] > v && line[2] < w) }' "$SVC/compose.yaml"
}

@test "mail add's result is valid compose, and the other services are unchanged" {
  real_compose_config
  lived_in
  use_svc
  before="$("$REAL_DOCKER" compose --project-directory "$SVC" config --format json | jq -S 'del(.services.mailpit, .volumes.mailpit)')"
  run vh cmd_mail add
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  after="$("$REAL_DOCKER" compose --project-directory "$SVC" config --format json)"
  [ "$(echo "$after" | jq -S 'del(.services.mailpit, .volumes.mailpit)')" = "$before" ]
  [ "$(echo "$after" | jq -r '.services.mailpit.image')" = "axllent/mailpit:v1.33" ]
  [ "$(echo "$after" | jq -r '.volumes.mysql.name')" = "precious_mysql" ]
  assert_contains "$(cat "$HOME/docker.log")" "up -d mailpit"
}

@test "mail add twice changes nothing the second time" {
  lived_in
  use_svc
  run vh cmd_mail add
  [ "$status" -eq 0 ]
  cp "$SVC/compose.yaml" "$HOME/once.yaml"
  # Stubbed compose doesn't know the file changed: this is the file's own check
  run vh cmd_mail add
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  assert_contains "$output" "already set up"
  cmp "$HOME/once.yaml" "$SVC/compose.yaml"
  [ "$(ls "$SVC"/compose.yaml.before-mailpit-* | wc -l | tr -d ' ')" = 1 ]
}

@test "mail add matches the file's indent, handles no final newline, and writes missing volumes" {
  real_compose_config
  use_svc
  printf 'services:\n    web:\n        image: nginx:1' >"$SVC/compose.yaml"
  run vh cmd_mail add
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  grep -qx '    mailpit:' "$SVC/compose.yaml"
  grep -qx '        image: nginx:1' "$SVC/compose.yaml"
  grep -qx 'volumes:' "$SVC/compose.yaml"
  "$REAL_DOCKER" compose --project-directory "$SVC" config -q
  [ "$("$REAL_DOCKER" compose --project-directory "$SVC" config --services | sort | tr '\n' ' ')" = "mailpit web " ]
}

@test "mail add ends a file with no final newline properly, on every platform" {
  use_svc
  printf 'services:\n  web:\n    image: nginx:1\nvolumes:\n  data:' >"$SVC/compose.yaml"
  run vh cmd_mail add
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  grep -qx '  data:' "$SVC/compose.yaml"
  grep -qx '  mailpit:' "$SVC/compose.yaml"
  [ "$(grep -c '^  mailpit:$' "$SVC/compose.yaml")" = 2 ]
}

@test "mail add takes a file whose services all use a named network" {
  real_compose_config
  use_svc
  printf 'services:\n  web:\n    image: nginx:1\n    networks: [back]\nnetworks:\n  back:\n' >"$SVC/compose.yaml"
  run vh cmd_mail add
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  grep -q '^  mailpit:$' "$SVC/compose.yaml"
  "$REAL_DOCKER" compose --project-directory "$SVC" config -q
}

@test "mail add still refuses when the result changes something else" {
  use_svc
  printf 'services:\n  web:\n    image: nginx:1\n' >"$SVC/compose.yaml"
  cp "$SVC/compose.yaml" "$HOME/before"
  cat >"$HOME/run.sh" <<'SH'
source "$VHOSTY_SRC"; trap cleanup_tmp EXIT; load_config
mail_config_rest() { echo "$2"; }
cmd_mail add
SH
  run env VHOSTY_SRC="$ROOT/bin/vhosty" bash "$HOME/run.sh"
  [ "$status" -ne 0 ]
  assert_contains "$output" "would have changed something else"
  cmp "$SVC/compose.yaml" "$HOME/before"
}

@test "mail add refuses services or volumes written in flow style, with or without compose" {
  use_svc
  printf 'services:\n  {web: {image: nginx}}\n' >"$SVC/compose.yaml"
  cp "$SVC/compose.yaml" "$HOME/before"
  run vh cmd_mail add
  [ "$status" -ne 0 ]
  assert_contains "$output" "not a plain block"
  cmp "$SVC/compose.yaml" "$HOME/before"
  printf 'services:\n  web:\n    image: nginx\nvolumes:\n  {a: {}}\n' >"$SVC/compose.yaml"
  run vh cmd_mail add
  [ "$status" -ne 0 ]
  assert_contains "$output" "not a plain block"
}

@test "mail add's temp copy is private, and leaves a file of the same name alone" {
  use_svc
  printf 'services:\n  web:\n    image: nginx:1\n' >"$SVC/compose.yaml"
  chmod 600 "$SVC/compose.yaml"
  echo mine >"$SVC/compose.yaml.vhosty-new"
  stub docker '
case "$*" in
  *" -f "*" config --services"*) while [ "$1" != "-f" ]; do shift; done; ls -l "$2" >>"$HOME/temp.log"; echo mailpit ;;
esac
exit 0'
  run vh cmd_mail add
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  assert_contains "$(cat "$HOME/temp.log")" "-rw-------"
  [ "$(cat "$SVC/compose.yaml.vhosty-new")" = mine ]
}

@test "mail add on a file it can't read says so, and shows the block" {
  [ "$(id -u)" != 0 ] || skip "root reads everything"
  use_svc
  printf 'services:\n  web:\n    image: nginx:1\n' >"$SVC/compose.yaml"
  chmod 000 "$SVC/compose.yaml"
  run vh cmd_mail add
  chmod 600 "$SVC/compose.yaml"
  [ "$status" -ne 0 ]
  assert_contains "$output" "isn't readable"
  assert_contains "$output" "Add this under services"
}

@test "an image: further in than a service's own keys isn't Mailpit" {
  use_svc
  printf 'services:\n  web:\n    image: nginx:1\n    environment:\n      image: mailpit\n' >"$SVC/compose.yaml"
  run vh cmd_mail add
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  refute_contains "$output" "already set up"
  grep -q '^  mailpit:$' "$SVC/compose.yaml"
}

@test "a Mailpit behind a compose profile is found" {
  real_compose_config
  use_svc
  printf 'services:\n  mailpit:\n    image: axllent/mailpit:v1.33\n    profiles: [mail]\n    ports: ["127.0.0.1:2025:1025"]\n' >"$SVC/compose.yaml"
  run vh cmd_mail
  refute_contains "$output" "Add it: vhosty mail add"
  printf '%s\n' "$output" | grep -qx "MAIL_PORT=2025"
}

@test "mail add copes with volumes above services, and one already named mailpit" {
  real_compose_config
  use_svc
  cat >"$SVC/compose.yaml" <<'YAML'
volumes:
    data:
services:
  web:
    image: nginx:1
    volumes: [data:/data]
YAML
  run vh cmd_mail add
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [ "$(sed -n 3p "$SVC/compose.yaml")" = "    mailpit:" ]
  "$REAL_DOCKER" compose --project-directory "$SVC" config -q

  cat >"$SVC/compose.yaml" <<'YAML'
services:
  web:
    image: nginx:1
volumes:
  mailpit:
YAML
  run vh cmd_mail add
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [ "$(grep -c '^  mailpit:$' "$SVC/compose.yaml")" = 2 ]   # the new service, the one volume
  "$REAL_DOCKER" compose --project-directory "$SVC" config -q
}

@test "mail add reads docker-compose.yml, the file compose would use" {
  use_svc
  printf 'services:\n  web:\n    image: nginx:1\n' >"$SVC/docker-compose.yml"
  run vh cmd_mail add
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  grep -q '^  mailpit:$' "$SVC/docker-compose.yml"
  [ ! -e "$SVC/compose.yaml" ]
}

@test "mail add keeps a symlinked file a symlink, with its permissions" {
  use_svc
  mkdir -p "$HOME/real"
  printf 'services:\n  web:\n    image: nginx:1\n' >"$HOME/real/c.yaml"
  chmod 640 "$HOME/real/c.yaml"
  ln -s "$HOME/real/c.yaml" "$SVC/compose.yaml"
  run vh cmd_mail add
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [ -L "$SVC/compose.yaml" ]
  grep -q '^  mailpit:$' "$HOME/real/c.yaml"
  [ "$(ls -l "$HOME/real/c.yaml" | cut -c1-10)" = "-rw-r-----" ]
}

@test "mail add with no compose file yet makes one with just Mailpit" {
  use_svc
  run vh cmd_mail add
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  grep -q '^  mailpit:$' "$SVC/compose.yaml"
  refute_contains "$(cat "$SVC/compose.yaml")" "mysql"
}

@test "mail add finds a compose.yaml in the default folder when none is configured" {
  mkdir -p "$VHOSTY_DIR/services"
  printf '# keep me\nservices:\n  web:\n    image: nginx:1\n' >"$VHOSTY_DIR/services/compose.yaml"
  run vh cmd_mail add
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  grep -q '^# keep me$' "$VHOSTY_DIR/services/compose.yaml"
  grep -q '^  mailpit:$' "$VHOSTY_DIR/services/compose.yaml"
  grep -q "VHOSTY_SERVICES_DIR=.*services" "$VHOSTY_DIR/config"
}

@test "mail add treats any service running the Mailpit image as Mailpit" {
  use_svc
  printf 'services:\n  catcher:\n    image: "docker.io/axllent/mailpit:latest"\n' >"$SVC/compose.yaml"
  cp "$SVC/compose.yaml" "$HOME/orig.yaml"
  run vh cmd_mail add
  [ "$status" -eq 0 ]
  assert_contains "$output" "already set up"
  cmp "$HOME/orig.yaml" "$SVC/compose.yaml"
}

@test "a commented-out Mailpit doesn't count" {
  use_svc
  printf 'services:\n  web:\n    image: nginx:1\n  # mailpit:\n  #   image: axllent/mailpit\n' >"$SVC/compose.yaml"
  run vh cmd_mail add
  [ "$status" -eq 0 ]
  grep -q '^  mailpit:$' "$SVC/compose.yaml"
  grep -q '^  # mailpit:$' "$SVC/compose.yaml"
}

# refused FILE-CONTENT REASON
refused() {
  printf "$1" >"$SVC/compose.yaml"
  cp "$SVC/compose.yaml" "$HOME/orig.yaml"
  use_svc
  run vh cmd_mail add
  [ "$status" -ne 0 ] || { echo "accepted: $1" >&2; false; }
  assert_contains "$output" "Can't safely edit"
  assert_contains "$output" "$2"
  assert_contains "$output" "wasn't changed"
  # The block to paste
  assert_contains "$output" "image: axllent/mailpit:v1.33"
  assert_contains "$output" '"127.0.0.1:8025:8025"'
  assert_contains "$output" "under the top-level volumes"
  cmp "$HOME/orig.yaml" "$SVC/compose.yaml"
  [ -z "$(ls "$SVC" | grep -v '^compose.yaml$' || true)" ]
}

@test "a file it can't safely edit is left alone, with the block to paste" {
  refused 'version: "3"\nname: nope\n' "no top-level services"
  refused 'services: {web: {image: nginx}}\n' "not a plain block"
  refused 'services: &all\n  web:\n    image: nginx\n' "not a plain block"
  refused 'services:\n  web:\n    image: nginx\nvolumes: {}\n' "not a plain block"
  refused 'services:\r\n  web:\r\n    image: nginx\r\n' "Windows line endings"
  refused 'services:\n  a:\n    image: x\n---\nname: other\n' "more than one YAML document"
  refused 'services:\n  a:\n    image: x\nservices:\n  b:\n    image: y\n' "two services"
  refused '{"services": {"web": {"image": "nginx"}}}\n' "no top-level services"
}

@test "a file compose can't read is left alone" {
  real_compose_config
  use_svc
  # Valid to the line scan, not to compose
  printf 'services:\n  web:\n    imagee: nginx:1\n    ports: {{\n' >"$SVC/compose.yaml"
  cp "$SVC/compose.yaml" "$HOME/orig.yaml"
  run vh cmd_mail add
  [ "$status" -ne 0 ]
  assert_contains "$output" "docker compose can't read it"
  cmp "$HOME/orig.yaml" "$SVC/compose.yaml"
}

@test "a service already on Mailpit's ports stops the add" {
  use_svc
  printf 'services:\n  mailhog:\n    image: mailhog/mailhog\n' >"$SVC/compose.yaml"
  echo '{"services":{"mailhog":{"image":"mailhog/mailhog","ports":[{"target":8025,"published":"8025"}]}}}' >"$HOME/config.json"
  cp "$SVC/compose.yaml" "$HOME/orig.yaml"
  run vh cmd_mail add
  [ "$status" -ne 0 ]
  assert_contains "$output" "mailhog already publishes"
  cmp "$HOME/orig.yaml" "$SVC/compose.yaml"
}

@test "a file that isn't writable is left alone" {
  [ "$(id -u)" != 0 ] || skip "root writes anyway"
  use_svc
  printf 'services:\n  web:\n    image: nginx:1\n' >"$SVC/compose.yaml"
  chmod 444 "$SVC/compose.yaml"
  run vh cmd_mail add
  [ "$status" -ne 0 ]
  assert_contains "$output" "isn't writable"
  assert_contains "$output" "under the top-level volumes"
}

@test "without docker, mail add still edits the file and says it couldn't check" {
  use_svc
  printf 'services:\n  web:\n    image: nginx:1\n' >"$SVC/compose.yaml"
  # A PATH without docker
  mkdir -p "$HOME/nodocker"
  # Everything else, as the rebuild that makes the proxy needs plenty
  IFS=: read -ra dirs <<<"$PATH"
  for d in "${dirs[@]}"; do
    for f in "$d"/*; do
      c="${f##*/}"
      if [ "$c" != docker ] && [ -x "$f" ] && [ ! -e "$HOME/nodocker/$c" ]; then ln -s "$f" "$HOME/nodocker/$c"; fi
    done
  done
  run env PATH="$HOME/nodocker" bash -c "source '$ROOT/bin/vhosty'; trap cleanup_tmp EXIT; load_config; cmd_mail add"
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  assert_contains "$output" "isn't here to check"
  grep -q '^  mailpit:$' "$SVC/compose.yaml"
  assert_contains "$output" "MAIL_PORT=1025"
}

@test "mail add doesn't start Mailpit when its ports are taken" {
  use_svc
  printf 'services:\n  web:\n    image: nginx:1\n' >"$SVC/compose.yaml"
  stub ss 'case "$*" in *8025*) echo "LISTEN 0 0 127.0.0.1:8025 0.0.0.0:* users:((\"other\",pid=1,fd=3))" ;; esac'
  stub lsof 'case "$*" in *8025*) printf "COMMAND PID\nother 1\n" ;; esac'
  run vh cmd_mail add
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  assert_contains "$output" "not starting it"
  refute_contains "$(cat "$HOME/docker.log")" "up -d"
}

# ---- vhosty mail ----

@test "vhosty mail prints the .env lines, each on its own line" {
  use_svc
  printf 'services:\n  mailpit:\n    image: axllent/mailpit:v1.33\n' >"$SVC/compose.yaml"
  mailpit_config
  run vh cmd_mail
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  for line in MAIL_MAILER=smtp MAIL_SCHEME=null MAIL_HOST=127.0.0.1 MAIL_PORT=1025 MAIL_USERNAME=null MAIL_PASSWORD=null MAIL_ENCRYPTION=null; do
    printf '%s\n' "$output" | grep -qx "$line" || { echo "missing $line: $output" >&2; false; }
  done
  assert_contains "$output" "MAIL_URL"
  assert_contains "$output" "never edits"
}

@test "vhosty mail says when Mailpit is running, stopped, or not there" {
  use_svc
  printf 'services:\n  mailpit:\n    image: axllent/mailpit:v1.33\n' >"$SVC/compose.yaml"
  mailpit_config
  echo '{"Service":"mailpit","State":"running","Health":"healthy","Publishers":[]}' >"$HOME/ps.json"
  run vh cmd_mail
  assert_contains "$output" "Mailpit running (healthy)"
  assert_contains "$output" "https://8025.test.example"
  refute_contains "$output" "once it's running"

  echo '{"Service":"mailpit","State":"exited","Health":"","Publishers":[]}' >"$HOME/ps.json"
  run vh cmd_mail
  [ "$status" -eq 0 ]
  assert_contains "$output" "Mailpit exited"
  assert_contains "$output" "vhosty services up mailpit"
  assert_contains "$output" "https://8025.test.example (once it's running)"

  echo '{"services":{"mysql":{"image":"mysql:8.4"}}}' >"$HOME/config.json"
  run vh cmd_mail
  [ "$status" -eq 0 ]
  assert_contains "$output" "Add it: vhosty mail add"
  assert_contains "$output" "MAIL_PORT=1025"
}

@test "vhosty mail with no services folder says how to set it up" {
  run vh cmd_mail
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  assert_contains "$output" "isn't set up"
  assert_contains "$output" "vhosty mail add"
  assert_contains "$output" "MAIL_MAILER=smtp"
}

@test "vhosty mail without Docker running still prints the lines" {
  use_svc
  printf 'services:\n  mailpit:\n    image: axllent/mailpit:v1.33\n' >"$SVC/compose.yaml"
  stub docker 'exit 1'
  run vh cmd_mail
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  assert_contains "$output" "Can't tell if Mailpit is running"
  assert_contains "$output" "MAIL_PORT=1025"
}

@test "vhosty mail with the Docker daemon down still gets the ports right" {
  use_svc
  printf 'services:\n  mailpit:\n    image: axllent/mailpit:v1.33\n' >"$SVC/compose.yaml"
  mailpit_config 2025 8026
  stub docker 'case "$*" in *" config"*) cat "$HOME/config.json"; exit 0 ;; esac; exit 1'
  run vh cmd_mail
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  assert_contains "$output" "Can't tell if Mailpit is running"
  printf '%s\n' "$output" | grep -qx "MAIL_PORT=2025"
  assert_contains "$output" "https://8026.test.example"
}

@test "vhosty mail says when compose can't read the file" {
  use_svc
  printf 'services:\n  mailpit:\n    image: axllent/mailpit:v1.33\n' >"$SVC/compose.yaml"
  stub docker 'case "$1 $*" in info*) exit 0 ;; compose*" config"*) exit 1 ;; esac; exit 0'
  run vh cmd_mail
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  assert_contains "$output" "can't read"
  refute_contains "$output" "Mailpit running"
}

@test "vhosty mail uses the ports Mailpit really publishes" {
  use_svc
  printf 'services:\n  mailpit:\n    image: axllent/mailpit:v1.33\n' >"$SVC/compose.yaml"
  mailpit_config 2025 8026
  run vh cmd_mail
  printf '%s\n' "$output" | grep -qx "MAIL_PORT=2025"
  assert_contains "$output" "https://8026.test.example"
}

@test "with 8025 out of VHOSTY_PORTS, vhosty mail says so and prints no dead URL" {
  use_svc 'VHOSTY_PORTS="3000-5999 8888"'
  printf 'services:\n  mailpit:\n    image: axllent/mailpit:v1.33\n' >"$SVC/compose.yaml"
  mailpit_config
  run vh cmd_mail
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  refute_contains "$output" "https://8025"
  assert_contains "$output" "VHOSTY_PORTS leaves out 8025"
  assert_contains "$output" 'VHOSTY_PORTS="3000-5999 8888 8025"'
  assert_contains "$output" "vhosty rebuild"
  assert_contains "$output" "http://127.0.0.1:8025"
}

@test "an empty VHOSTY_PORTS closes the mail page too" {
  use_svc 'VHOSTY_PORTS=""'
  printf 'services:\n  mailpit:\n    image: axllent/mailpit:v1.33\n' >"$SVC/compose.yaml"
  mailpit_config
  run vh cmd_mail
  refute_contains "$output" "https://8025"
  assert_contains "$output" 'VHOSTY_PORTS="8025"'
}

@test "the port check agrees with the Caddyfile: 8025 is forwarded by default" {
  run vh mail_port_open 8025
  [ "$status" -eq 0 ]
  run vh mail_port_open 8125
  [ "$status" -ne 0 ]
  run vh mail_port_open 1025
  [ "$status" -ne 0 ]
  # The generator's own expression, for the default ranges
  run vh port_expr 2
  assert_contains "$output" "int({labels.2}) >= 8000 && int({labels.2}) <= 8099"
}

@test "an unknown mail command says how to use it" {
  run vh cmd_mail frobnicate
  [ "$status" -ne 0 ]
  assert_contains "$output" "Usage: vhosty mail"
}

@test "main knows the mail command, Herd or not" {
  run bash -c "source '$ROOT/bin/vhosty'; main mail"
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  assert_contains "$output" "MAIL_MAILER=smtp"
  write_config 'VHOSTY_BACKEND="herd"'
  run bash -c "source '$ROOT/bin/vhosty'; main mail"
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  assert_contains "$output" "MAIL_MAILER=smtp"
}

@test "usage and completions know about mail" {
  run bash -c "source '$ROOT/bin/vhosty'; usage"
  assert_contains "$output" "vhosty mail add"
  grep -q "'mail:" "$ROOT/completions/_vhosty"
  grep -q "typesense rustfs mailpit" "$ROOT/completions/_vhosty"
}

# ---- doctor ----

@test "doctor's note names the sites using Mailpit, and never a value from .env" {
  use_svc
  printf 'services:\n  mailpit:\n    image: axllent/mailpit:v1.33\n' >"$SVC/compose.yaml"
  mailpit_config
  php_site caught; php_site quoted; php_site real; php_site noenv; php_site otherport
  printf 'MAIL_HOST=127.0.0.1\nMAIL_PORT=1025\nMAIL_PASSWORD=hunter2secret\n' >"$PARKED/caught/.env"
  printf 'MAIL_HOST="localhost" # local\nMAIL_PORT="1025"\n' >"$PARKED/quoted/.env"
  printf 'MAIL_HOST=smtp.example.com\nMAIL_PORT=1025\nMAIL_PASSWORD=hunter2secret\n' >"$PARKED/real/.env"
  printf 'MAIL_HOST=127.0.0.1\nMAIL_PORT=2525\n' >"$PARKED/otherport/.env"
  run vh mail_doctor_info
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  assert_contains "$output" "caught"
  assert_contains "$output" "quoted"
  refute_contains "$output" "real"
  refute_contains "$output" "otherport"
  refute_contains "$output" "hunter2secret"
  refute_contains "$output" "smtp.example.com"
}

@test "doctor runs the note" {
  use_svc
  printf 'services:\n  mailpit:\n    image: axllent/mailpit:v1.33\n' >"$SVC/compose.yaml"
  mailpit_config
  php_site caught
  printf 'MAIL_HOST=127.0.0.1\nMAIL_PORT=1025\n' >"$PARKED/caught/.env"
  run linux main doctor
  assert_contains "$output" "sites sending mail to Mailpit: caught"
}

@test "doctor's note ignores a folder named .env" {
  use_svc
  printf 'services:\n  mailpit:\n    image: axllent/mailpit:v1.33\n' >"$SVC/compose.yaml"
  mailpit_config
  php_site odd
  mkdir "$PARKED/odd/.env"
  run vh mail_doctor_info
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "doctor's note can't fail, and says nothing without Mailpit" {
  use_svc
  printf 'services:\n  web:\n    image: nginx:1\n' >"$SVC/compose.yaml"
  php_site caught
  printf 'MAIL_HOST=127.0.0.1\nMAIL_PORT=1025\n' >"$PARKED/caught/.env"
  run vh mail_doctor_info
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  stub docker 'exit 1'
  run vh mail_doctor_info
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---- backup and restore ----

backup_stub() {
  stub docker '
echo "docker $*" >>"$HOME/docker.log"
case "$1" in
  compose)
    case "$*" in
      *" config --format json"*) echo "{\"services\":{\"valkey\":{\"image\":\"valkey/valkey:9-alpine\"},\"mailpit\":{\"image\":\"axllent/mailpit:v1.33\"}}}" ;;
      *" ps -q"*) case "$*" in *valkey*) echo cid-valkey ;; *mailpit*) echo cid-mailpit ;; esac ;;
    esac ;;
  inspect)
    case "$*" in
      *State.Running*) echo true ;;
      *cid-valkey*) echo "volume|svc_valkey|/data" ;;
      *) echo "volume|svc_mailpit|/data" ;;
    esac ;;
  run) printf "archive" ;;
esac
exit 0'
}

@test "a backup leaves out caught mail on purpose, and keeps Mailpit running" {
  use_svc
  printf 'services:\n  valkey:\n    image: valkey/valkey:9-alpine\n  mailpit:\n    image: axllent/mailpit:v1.33\n' >"$SVC/compose.yaml"
  backup_stub
  run vh cmd_services_backup --to "$HOME/backups"
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  assert_contains "$output" "caught mail isn't backed up"
  # Not in the "not backed up" warning: this one isn't a surprise
  refute_contains "$output" "not backed up:"
  b="$(ls -d "$HOME"/backups/services-*)"
  grep -q '^volume|valkey|' "$b/MANIFEST"
  run grep -c 'mailpit' "$b/MANIFEST"
  [ "$output" = 0 ]
  [ ! -e "$b/mailpit" ]
  refute_contains "$(cat "$HOME/docker.log")" "stop mailpit"
  # The compose file with Mailpit in it is saved
  grep -q '^  mailpit:$' "$b/config/compose.yaml"
}

@test "a restore brings Mailpit back, empty, from the saved compose file" {
  use_svc
  printf 'services:\n  valkey:\n    image: valkey/valkey:9-alpine\n  mailpit:\n    image: axllent/mailpit:v1.33\n' >"$SVC/compose.yaml"
  backup_stub
  run vh cmd_services_backup --to "$HOME/backups"
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  b="$(ls -d "$HOME"/backups/services-*)"
  : >"$HOME/docker.log"
  run vh cmd_services_restore "$b" --into "$HOME/restored" --yes
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  grep -q '^  mailpit:$' "$HOME/restored/compose.yaml"
  assert_contains "$output" "valkey: /data restored"
  refute_contains "$output" "mailpit: /data"
  assert_contains "$(cat "$HOME/docker.log")" "up -d"
}

@test "service_kind knows Mailpit, by its image's own name" {
  [ "$(vh service_kind axllent/mailpit:v1.33)" = mail ]
  [ "$(vh service_kind docker.io/axllent/mailpit)" = mail ]
  [ "$(vh service_kind someone/mailpit-exporter:1)" = volume ]
}

# ---------------------------------------------------------------- mail.<domain>

mail_config() { # mail_config [SMTP] [WEB]: the file exists, and compose reports Mailpit
  mkdir -p "$SVC"
  printf 'services:\n  mailpit:\n    image: axllent/mailpit:v1.33\n' >"$SVC/compose.yaml"
  echo "VHOSTY_SERVICES_DIR=\"$SVC\"" >>"$VHOSTY_DIR/config"
  echo '{"services":{"mailpit":{"image":"axllent/mailpit:v1.33","ports":[{"target":1025,"published":"'"${1:-1025}"'"},{"target":8025,"published":"'"${2:-8025}"'"}]}}}' >"$HOME/config.json"
}

@test "mail add gives the page mail.<domain>, and vhosty mail prints it" {
  mail_config
  run linux main mail add
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  assert_contains "$output" "https://mail.test.example → localhost:8025"
  assert_contains "$output" "Caught mail: https://mail.test.example"
  [ "$(sed -n 's/^PROXY_PORT=//p' "$VHOSTY_DIR/proxies/mail.conf")" = 8025 ]
  grep -q "reverse_proxy localhost:8025" "$VHOSTY_DIR/Caddyfile"
  run linux main mail
  assert_contains "$output" "Caught mail: https://mail.test.example"
  refute_contains "$output" "https://8025"
}

@test "mail add a second time leaves the proxy be, quietly" {
  mail_config
  linux main mail add >/dev/null 2>&1
  before="$(cat "$VHOSTY_DIR/proxies/mail.conf")"
  run linux main mail add
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  refute_contains "$output" "left it alone"
  refute_contains "$output" "tailnet can"
  [ "$(cat "$VHOSTY_DIR/proxies/mail.conf")" = "$before" ]
}

@test "mail add uses the port Mailpit really publishes" {
  mail_config 1125 18025
  sed -i.bak 's/^VHOSTY_DOMAIN=.*/&\nVHOSTY_PORTS="3000-5999 18025"/' "$VHOSTY_DIR/config"
  run linux main mail add
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [ "$(sed -n 's/^PROXY_PORT=//p' "$VHOSTY_DIR/proxies/mail.conf")" = 18025 ]
}

@test "a Mailpit publishing no web page gets no proxy" {
  mail_config
  echo '{"services":{"mailpit":{"image":"axllent/mailpit:v1.33","ports":[{"target":1025,"published":"1025"}]}}}' >"$HOME/config.json"
  run linux main mail add
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [ ! -e "$VHOSTY_DIR/proxies/mail.conf" ]
  assert_contains "$output" "doesn't publish its web page"
}

@test "a parked folder called mail stays, with a warning, even if it isn't a site" {
  mail_config
  mkdir -p "$PARKED/mail"
  run linux main mail add
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  assert_contains "$output" "$PARKED/mail already exists"
  assert_contains "$output" "https://8025.test.example"
  assert_contains "$output" "Caught mail: https://8025.test.example"
  [ ! -e "$VHOSTY_DIR/proxies/mail.conf" ]
  [ -d "$PARKED/mail" ]
}

@test "a folder called Mail counts, as hostnames ignore case" {
  mail_config
  mkdir -p "$PARKED/Mail"
  run linux main mail add
  assert_contains "$output" "$PARKED/Mail already exists"
  [ ! -e "$VHOSTY_DIR/proxies/mail.conf" ]
}

@test "a linked site called mail stays, with a warning" {
  mail_config
  mkdir -p "$HOME/app/public"
  echo '<?php' >"$HOME/app/public/index.php"
  run linux main link "$HOME/app" --name mail
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  run linux main mail add
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  assert_contains "$output" "already a site called mail"
  assert_contains "$output" "Caught mail: https://8025.test.example"
  [ ! -e "$VHOSTY_DIR/proxies/mail.conf" ]
}

@test "someone's proxy called mail, on another port, stays" {
  mail_config
  run linux main proxy mail 3000
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  run linux main mail add
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  assert_contains "$output" "goes to port 3000"
  assert_contains "$output" "Caught mail: https://8025.test.example"
  [ "$(sed -n 's/^PROXY_PORT=//p' "$VHOSTY_DIR/proxies/mail.conf")" = 3000 ]
}

@test "removing the proxy puts vhosty mail back on the port's URL" {
  mail_config
  linux main mail add >/dev/null 2>&1
  run linux main unproxy mail
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  run linux main mail
  assert_contains "$output" "Caught mail: https://8025.test.example"
}

@test "mail add doesn't open a page VHOSTY_PORTS closed" {
  mail_config
  echo 'VHOSTY_PORTS="3000-5999"' >>"$VHOSTY_DIR/config"
  run linux main mail add
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [ ! -e "$VHOSTY_DIR/proxies/mail.conf" ]
  assert_contains "$output" "VHOSTY_PORTS leaves out 8025"
}

@test "services init with Mailpit gives it the address too, and without it doesn't" {
  run linux main services init "$SVC" --only mailpit
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [ -f "$VHOSTY_DIR/proxies/mail.conf" ]
  rm "$VHOSTY_DIR/proxies/mail.conf"
  run linux main services init "$HOME/svc2" --only valkey
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [ ! -e "$VHOSTY_DIR/proxies/mail.conf" ]
}

@test "under Herd, no proxy: that route is Herd's" {
  mail_config
  echo 'VHOSTY_BACKEND="herd"' >>"$VHOSTY_DIR/config"
  run vh mail_domain 8025
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [ ! -e "$VHOSTY_DIR/proxies/mail.conf" ]
}

