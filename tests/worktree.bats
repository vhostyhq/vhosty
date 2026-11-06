#!/usr/bin/env bats
# vhosty worktree: a git worktree as a site of its own. Real git in temp repos;
# docker is a stub that runs vhosty's snippets for real (in sh), with stub
# mysql, mysqldump, psql and pg_dump that keep their "databases" as files in
# $HOME/db and log every statement. Nothing here reaches a real database.

load helpers

# Found before vhosty_setup points HOME at a scratch folder
CADDY="${VHOSTY_TEST_CADDY:-$HOME/.vhosty/bin/caddy}"
PORT=18449

setup() {
  # Real paths from the start (macOS's temp folder is behind a symlink), so
  # that what git reports matches $HOME; the symlink cases make their own
  BATS_TEST_TMPDIR="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  vhosty_setup
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
  export GIT_CONFIG_NOSYSTEM=1
  git config --global init.defaultBranch main
  git config --global advice.detachedHead false
  # Nothing here may reach this machine's real services
  stub systemctl 'echo "systemctl $*" >>"$HOME/systemctl.log"; exit 1'
  stub composer 'echo "composer $* (in $PWD) php=$(command -v php)" >>"$HOME/composer.log"; [ ! -f "$HOME/composer-fails" ]'
  fake_docker
}

teardown() {
  [ -z "${CADDY_PID:-}" ] || kill "$CADDY_PID" 2>/dev/null || true
}

vhosty() { bash "$ROOT/bin/vhosty" "$@"; }

# repo_site NAME [.env text]: a parked site that's a git repository, with .env ignored
repo_site() {
  local d="$PARKED/$1"
  mkdir -p "$d/public" "$d/database"
  echo '<?php' >"$d/public/index.php"
  printf '.env\n*.sqlite\n/vendor\n' >"$d/.gitignore"
  echo keep >"$d/database/.gitkeep"
  [ $# -lt 2 ] || printf '%s\n' "$2" >"$d/.env"
  git -C "$d" init -q
  git -C "$d" add -A
  git -C "$d" commit -qm first
}

# A running MySQL and Postgres in vhosty's docker services
services_on() {
  mkdir -p "$HOME/svc"
  write_config "VHOSTY_SERVICES_DIR=\"$HOME/svc\""
}

MYSQL_ENV='APP_NAME=Ledger
APP_KEY=base64:secretkey
APP_URL=https://ledger.test.example
DB_CONNECTION=mysql
DB_HOST=127.0.0.1
DB_PORT=3306
DB_DATABASE=ledger
DB_USERNAME=root
DB_PASSWORD=hunter2secret'

PG_ENV='APP_KEY=base64:secretkey
DB_CONNECTION=pgsql
DB_HOST=127.0.0.1
DB_PORT=5432
DB_DATABASE=ledger
DB_USERNAME=ledger_app
DB_PASSWORD=hunter2secret'

SQLITE_ENV='APP_KEY=base64:secretkey
DB_CONNECTION=sqlite'

# docker: compose config and ps from these files; exec runs the snippet in this shell's PATH
fake_docker() {
  mkdir -p "$HOME/db/mysql" "$HOME/db/postgres" "$HOME/ids"
  cat >"$HOME/compose.json" <<'JSON'
{"services":{
  "mysql":{"image":"mysql:8.4","ports":[{"mode":"ingress","host_ip":"127.0.0.1","target":3306,"published":"3306","protocol":"tcp"}]},
  "postgres":{"image":"pgvector/pgvector:pg18-trixie","ports":[{"mode":"ingress","host_ip":"127.0.0.1","target":5432,"published":"5432","protocol":"tcp"}]},
  "valkey":{"image":"valkey/valkey:9-alpine","ports":[{"mode":"ingress","host_ip":"127.0.0.1","target":6379,"published":"6379","protocol":"tcp"}]}
}}
JSON
  cat >"$HOME/ps.json" <<'JSON'
{"Service":"mysql","State":"running","Health":"healthy","Publishers":[{"URL":"127.0.0.1","TargetPort":3306,"PublishedPort":3306}]}
{"Service":"postgres","State":"running","Health":"healthy","Publishers":[{"URL":"127.0.0.1","TargetPort":5432,"PublishedPort":5432}]}
JSON
  stub docker 'printf "%s\n" "docker $*" >>"$HOME/docker.log"
case "$1" in info) exit 0 ;; compose) ;; *) exit 1 ;; esac
shift 3   # compose --project-directory DIR
case "$1" in
  config) [ ! -f "$HOME/compose-fails" ] && cat "$HOME/compose.json" ;;
  ps) cat "$HOME/ps.json" ;;
  exec)
    shift; [ "$1" != "-T" ] || shift; shift   # -T, the service
    [ ! -f "$HOME/exec-fails" ] || exit 1
    "$@" ;;
  *) exit 1 ;;
esac'
  # mysql: the statement from -e, or SQL on stdin into the database named last
  stub mysql 'sql=""; db=""
while [ $# -gt 0 ]; do case "$1" in -e) sql="$2"; shift 2 ;; -*) shift ;; *) db="$1"; shift ;; esac; done
if [ -z "$sql" ]; then
  in="$(cat)"
  printf "%s\n" "load into ${db:-(none)}: $in" >>"$HOME/sql.log"
  if [ -n "$db" ]; then
    [ -e "$HOME/db/mysql/$db" ] || exit 1
    printf "%s\n" "$in" >>"$HOME/db/mysql/$db"
  fi
  exit 0
fi
printf "%s\n" "$sql" >>"$HOME/sql.log"
n="$(printf "%s" "$sql" | sed -n "s/.*\`\([^\`]*\)\`.*/\1/p")"
case "$sql" in
  *information_schema.schemata*) n="$(printf "%s" "$sql" | sed -n "s/.*schema_name = .\(.*\).$/\1/p")"
    if [ -e "$HOME/db/mysql/$n" ]; then echo 1; else echo 0; fi ;;
  "CREATE DATABASE"*) [ ! -e "$HOME/db/mysql/$n" ] || exit 1; [ ! -f "$HOME/create-fails" ] || exit 1; : >"$HOME/db/mysql/$n" ;;
  "DROP DATABASE"*) [ ! -f "$HOME/drop-fails" ] || exit 1; [ -e "$HOME/db/mysql/$n" ] || exit 1; rm -f "$HOME/db/mysql/$n" ;;
  select\ concat*) echo "GRANT ALL PRIVILEGES ON \`$n\`.* TO $(printf "%s" "$sql" | sed -n "s/.*User = \(.*\)$/\1/p")@%;" ;;
  *) exit 1 ;;
esac'
  stub mysqldump 'printf "%s\n" "mysqldump $*" >>"$HOME/dump.log"; [ ! -f "$HOME/dump-fails" ] || exit 1
for last; do :; done; printf "%s\n" "-- data of $last"; cat "$HOME/db/mysql/$last"'
  # psql: -c or -Atc statements; SQL on stdin into -d
  stub psql 'sql=""; db=""
while [ $# -gt 0 ]; do case "$1" in -c|-Atc|-qc) sql="$2"; shift 2 ;; -d) db="$2"; shift 2 ;; -U|-v) shift 2 ;; *) shift ;; esac; done
if [ -z "$sql" ]; then
  in="$(cat)"
  printf "%s\n" "load into $db: $in" >>"$HOME/sql.log"
  [ -e "$HOME/db/postgres/$db" ] || exit 1
  printf "%s\n" "$in" >>"$HOME/db/postgres/$db"
  exit 0
fi
printf "%s\n" "$sql" >>"$HOME/sql.log"
n="$(printf "%s" "$sql" | sed -n "s/^[A-Z ]*DATABASE \"\([^\"]*\)\".*/\1/p")"
case "$sql" in
  *"from pg_database"*) n="$(printf "%s" "$sql" | sed -n "s/.*datname = .\(.*\).$/\1/p")"
    if [ -e "$HOME/db/postgres/$n" ]; then echo 1; else echo 0; fi ;;
  *"from pg_roles"*) echo 1 ;;
  *"from pg_extension"*) echo vector ;;
  "CREATE EXTENSION"*) ;;
  "CREATE DATABASE"*) [ ! -e "$HOME/db/postgres/$n" ] || exit 1; : >"$HOME/db/postgres/$n" ;;
  "DROP DATABASE"*) [ ! -f "$HOME/drop-fails" ] || exit 1; rm -f "$HOME/db/postgres/$n" ;;
  *) exit 1 ;;
esac'
  stub pg_dump 'printf "%s\n" "pg_dump $*" >>"$HOME/dump.log"; [ ! -f "$HOME/dump-fails" ] || exit 1
for last; do :; done; printf "%s\n" "-- data of $last"; cat "$HOME/db/postgres/$last"'
}

# mysql_db NAME / pg_db NAME: a database that's there, with some data
mysql_db() { echo "row of $1" >"$HOME/db/mysql/$1"; }
pg_db() { echo "row of $1" >"$HOME/db/postgres/$1"; }

conf() { cat "$VHOSTY_DIR/sites/$1.conf"; }
conf_value() { ( . "$VHOSTY_DIR/sites/$1.conf"; eval "printf %s \"\$$2\"" ); }

# ---------------------------------------------------------------- names

@test "names: <branch>--<site>, sanitised to one lowercase DNS label" {
  [ "$(vh worktree_name feature/x ledger)" = "feature-x--ledger" ]
  [ "$(vh worktree_name Fix_THE.Bug ledger)" = "fix-the-bug--ledger" ]
  [ "$(vh worktree_name a--b ledger)" = "a-b--ledger" ]
  [ "$(vh worktree_name -lead/trail- ledger)" = "lead-trail--ledger" ]
  [ "$(vh worktree_name 'q"uo;te$(x)' ledger)" = "q-uo-te-x--ledger" ]
}

@test "names: a branch with nothing usable still gets a stable, valid name" {
  a="$(vh worktree_name '日本語' ledger)"
  b="$(vh worktree_name '日本語' ledger)"
  c="$(vh worktree_name 'русский' ledger)"
  [ "$a" = "$b" ]
  [ "$a" != "$c" ]
  vh valid_name "$a"
  assert_contains "$a" "--ledger"
}

@test "names: never starts xn--, which browsers read as an encoded name" {
  n="$(vh worktree_name xn ledger)"
  case "$n" in xn--*) false ;; esac
  vh valid_name "$n"
  [ "$(vh worktree_name xn--foo ledger)" = "xn-foo--ledger" ]
}

@test "names: too long for a label, cut with a hash of the original" {
  long="$(printf 'feature/%.0sabcdefghij' 1 2 3 4 5 6 7 8)"
  a="$(vh worktree_name "${long}one" ledger)"
  b="$(vh worktree_name "${long}two" ledger)"
  [ ${#a} -le 63 ]
  [ ${#b} -le 63 ]
  [ "$a" != "$b" ]
  [ "$a" = "$(vh worktree_name "${long}one" ledger)" ]
  vh valid_name "$a"
  assert_contains "$a" "--ledger"
}

@test "names: exactly 63 stays as it is, and a very long site is cut too" {
  b="$(printf 'b%.0s' $(seq 1 55))"
  [ "$(vh worktree_name "$b" ledger)" = "$b--ledger" ]
  [ ${#b} -eq 55 ]
  site="$(printf 'site-%.0s' $(seq 1 11))x"
  [ ${#site} -le 63 ]
  n="$(vh worktree_name feature/x "$site")"
  [ ${#n} -le 63 ]
  vh valid_name "$n"
  assert_contains "$n" "feature-x-"
}

@test "database names: a plain identifier of at most 63" {
  [ "$(vh worktree_db_name feature-x--ledger)" = "wt_feature_x__ledger" ]
  long="$(printf 'a%.0s' $(seq 1 63))"
  n="$(vh worktree_db_name "$long")"
  [ ${#n} -le 63 ]
  vh worktree_db_name_ok "$n"
}

@test "database names: anything that isn't vhosty's own shape is refused" {
  vh worktree_db_name_ok wt_ok_1
  ! vh worktree_db_name_ok ledger
  ! vh worktree_db_name_ok 'wt_x`; DROP DATABASE ledger'
  ! vh worktree_db_name_ok 'wt_"x'
  ! vh worktree_db_name_ok ''
}

# ---------------------------------------------------------------- .env helpers

@test ".env reading: quotes, comments, export, and no partial key matches" {
  cat >"$HOME/e" <<'EOF2'
# DB_DATABASE=commented
A=plain # comment
B="quoted # value"
C='single'
export D=exported
DB_HOST2=wrong
E=
EOF2
  [ "$(vh worktree_env_get "$HOME/e" DB_DATABASE)" = "" ]
  [ "$(vh worktree_env_get "$HOME/e" A)" = "plain" ]
  [ "$(vh worktree_env_get "$HOME/e" B)" = "quoted # value" ]
  [ "$(vh worktree_env_get "$HOME/e" C)" = "single" ]
  [ "$(vh worktree_env_get "$HOME/e" D)" = "exported" ]
  [ "$(vh worktree_env_get "$HOME/e" DB_HOST)" = "" ]
  [ "$(vh worktree_env_get "$HOME/e" E)" = "" ]
}

@test ".env writing: replaces, appends, quotes, keeps the mode and other lines" {
  printf 'A=1\n# B=old\nC=$KEEP "as is"\n' >"$HOME/e"
  chmod 640 "$HOME/e"
  vh worktree_env_set "$HOME/e" A 'two'
  vh worktree_env_set "$HOME/e" B '/a path/with $dollar'
  [ "$(sed -n 1p "$HOME/e")" = "A=two" ]
  [ "$(sed -n 2p "$HOME/e")" = "# B=old" ]
  [ "$(sed -n 3p "$HOME/e")" = 'C=$KEEP "as is"' ]
  [ "$(sed -n 4p "$HOME/e")" = "B='/a path/with \$dollar'" ]
  [ "$(vh worktree_env_get "$HOME/e" B)" = '/a path/with $dollar' ]
  [ "$(ls -l "$HOME/e" | cut -c1-10)" = "-rw-r-----" ]
}

@test ".env writing never goes through a symlink" {
  printf 'A=target\n' >"$HOME/target"
  ln -s "$HOME/target" "$HOME/e"
  vh worktree_env_set "$HOME/e" A changed
  [ "$(cat "$HOME/target")" = "A=target" ]
  [ ! -L "$HOME/e" ]
  [ "$(cat "$HOME/e")" = "A=changed" ]
}

# ---------------------------------------------------------------- add

@test "add: makes the worktree, the branch, the site, outside the parked folder" {
  repo_site ledger "$MYSQL_ENV"
  services_on
  cd "$PARKED/ledger"
  run vhosty worktree add feature/x
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  dir="$VHOSTY_DIR/worktrees/ledger/feature-x"
  [ -d "$dir/public" ]
  [ "$(git -C "$dir" symbolic-ref --short HEAD)" = "feature/x" ]
  [ "$(conf_value feature-x--ledger SITE_WT_KIND)" = created ]
  [ "$(conf_value feature-x--ledger SITE_WT_PARENT)" = ledger ]
  [ "$(conf_value feature-x--ledger SITE_WT_BRANCH)" = feature/x ]
  [ "$(conf_value feature-x--ledger SITE_PATH)" = "$(cd "$dir" && pwd -P)" ]
  assert_contains "$output" "https://feature-x--ledger.test.example"
  assert_contains "$output" "php artisan migrate --seed"
}

@test "add: the parent's .env is untouched, byte for byte, and its mode is kept" {
  repo_site ledger "$MYSQL_ENV"
  printf 'NO_NEWLINE_AT_END="x"' >>"$PARKED/ledger/.env"
  chmod 600 "$PARKED/ledger/.env"
  before="$(cksum <"$PARKED/ledger/.env")"
  services_on
  cd "$PARKED/ledger"
  run vhosty worktree add feature/x
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [ "$(cksum <"$PARKED/ledger/.env")" = "$before" ]
  wt="$VHOSTY_DIR/worktrees/ledger/feature-x/.env"
  [ "$(ls -l "$wt" | cut -c1-10)" = "-rw-------" ]
  [ "$(vh worktree_env_get "$wt" APP_URL)" = "https://feature-x--ledger.test.example" ]
  [ "$(vh worktree_env_get "$wt" DB_DATABASE)" = "wt_feature_x__ledger" ]
  [ "$(vh worktree_env_get "$wt" APP_KEY)" = "base64:secretkey" ]
  [ "$(vh worktree_env_get "$PARKED/ledger/.env" DB_DATABASE)" = "ledger" ]
}

@test "add: with no .env in the parent, starts from .env.example" {
  repo_site ledger
  printf 'APP_KEY=\nDB_CONNECTION=sqlite\n' >"$PARKED/ledger/.env.example"
  git -C "$PARKED/ledger" add -A; git -C "$PARKED/ledger" commit -qm example
  touch "$PARKED/ledger/artisan"
  cd "$PARKED/ledger"
  run vhosty worktree add feature/x
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [ -f "$VHOSTY_DIR/worktrees/ledger/feature-x/.env" ]
  [ ! -e "$PARKED/ledger/.env" ]
  assert_contains "$output" ".env from .env.example"
}

@test "add: with no .env and no example, says so and still makes the site" {
  repo_site ledger
  cd "$PARKED/ledger"
  run vhosty worktree add feature/x
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [ ! -e "$VHOSTY_DIR/worktrees/ledger/feature-x/.env" ]
  assert_contains "$output" "no .env"
  [ -f "$VHOSTY_DIR/sites/feature-x--ledger.conf" ]
}

@test "--copy-db with nothing to copy from says so" {
  repo_site ledger
  cd "$PARKED/ledger"
  run vhosty worktree add feature/x --copy-db
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  assert_contains "$output" "--copy-db did nothing"
}

@test "add: --site works from anywhere" {
  repo_site ledger
  cd "$HOME"
  run vhosty worktree add feature/x --site ledger
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [ -d "$VHOSTY_DIR/worktrees/ledger/feature-x" ]
}

@test "add: an existing local branch is checked out, not recreated" {
  repo_site ledger
  git -C "$PARKED/ledger" branch existing
  sha="$(git -C "$PARKED/ledger" rev-parse existing)"
  echo more >"$PARKED/ledger/more"; git -C "$PARKED/ledger" add -A; git -C "$PARKED/ledger" commit -qm more
  cd "$PARKED/ledger"
  run vhosty worktree add existing
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [ "$(git -C "$VHOSTY_DIR/worktrees/ledger/existing" rev-parse HEAD)" = "$sha" ]
}

@test "add: a branch only on a remote is checked out, tracking it" {
  git init -q --bare "$HOME/remote.git"
  repo_site ledger
  git -C "$PARKED/ledger" remote add origin "$HOME/remote.git"
  git -C "$PARKED/ledger" push -q origin main:refs/heads/from-remote
  git -C "$PARKED/ledger" fetch -q origin
  cd "$PARKED/ledger"
  run vhosty worktree add from-remote
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [ "$(git -C "$VHOSTY_DIR/worktrees/ledger/from-remote" rev-parse --abbrev-ref '@{upstream}')" = "origin/from-remote" ]
}

@test "add: a new branch starts at the current HEAD" {
  repo_site ledger
  sha="$(git -C "$PARKED/ledger" rev-parse HEAD)"
  cd "$PARKED/ledger"
  run vhosty worktree add brand-new
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [ "$(git -C "$VHOSTY_DIR/worktrees/ledger/brand-new" rev-parse HEAD)" = "$sha" ]
}

@test "add: from inside a worktree site, the parent stays the main site, from that HEAD" {
  repo_site ledger
  cd "$PARKED/ledger"
  run vhosty worktree add one
  [ "$status" -eq 0 ]
  cd "$VHOSTY_DIR/worktrees/ledger/one"
  echo x >x; git add -A; git commit -qm on-one
  sha="$(git rev-parse HEAD)"
  run vhosty worktree add two
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [ "$(conf_value two--ledger SITE_WT_PARENT)" = ledger ]
  [ "$(git -C "$VHOSTY_DIR/worktrees/ledger/two" rev-parse HEAD)" = "$sha" ]
}

@test "add: a branch checked out elsewhere is refused, with git's reason, and nothing set up" {
  repo_site ledger
  git -C "$PARKED/ledger" branch taken
  git -C "$PARKED/ledger" worktree add -q "$HOME/elsewhere" taken
  cd "$PARKED/ledger"
  run vhosty worktree add taken
  [ "$status" -ne 0 ]
  assert_contains "$output" "git wouldn't"
  assert_contains "$output" "taken"
  [ ! -e "$VHOSTY_DIR/sites/taken--ledger.conf" ]
  [ ! -e "$VHOSTY_DIR/worktrees/ledger" ]
}

@test "add: refuses a name collision with a site, and changes nothing" {
  repo_site ledger
  mkdir -p "$HOME/other"
  site_conf feature-x--ledger "SITE_PATH=$HOME/other
SITE_LINKED=yes"
  cd "$PARKED/ledger"
  run vhosty worktree add feature/x
  [ "$status" -ne 0 ]
  assert_contains "$output" "already a site"
  ! git -C "$PARKED/ledger" show-ref --verify --quiet refs/heads/feature/x
  # two branches can also land on one name
  run vhosty worktree add feature-x
  [ "$status" -ne 0 ]
}

@test "add: refuses a name a parked folder already answers to" {
  repo_site ledger
  static_site feature-x--ledger
  cd "$PARKED/ledger"
  run vhosty worktree add feature/x
  [ "$status" -ne 0 ]
  assert_contains "$output" "parked"
}

@test "add: --path works, but not directly inside a parked folder" {
  repo_site ledger
  cd "$PARKED/ledger"
  run vhosty worktree add one --path "$PARKED/one"
  [ "$status" -ne 0 ]
  assert_contains "$output" "parked folder"
  ! git -C "$PARKED/ledger" show-ref --verify --quiet refs/heads/one
  run vhosty worktree add one --path "$HOME/my worktrees/one"
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [ -d "$HOME/my worktrees/one/public" ]
  [ "$(conf_value one--ledger SITE_PATH)" = "$(cd "$HOME/my worktrees/one" && pwd -P)" ]
}

@test "add: a site that isn't a git repository, or isn't at its root, is refused" {
  php_site plain
  cd "$PARKED/plain"
  run vhosty worktree add x
  [ "$status" -ne 0 ]
  assert_contains "$output" "isn't a git repository"
  mkdir -p "$HOME/mono/app"
  git -C "$HOME/mono" init -q
  git -C "$HOME/mono" commit -q --allow-empty -m x
  site_conf app "SITE_PATH=$HOME/mono/app
SITE_LINKED=yes"
  run vhosty worktree add x --site app
  [ "$status" -ne 0 ]
  assert_contains "$output" "not at its root"
}

@test "add: outside any site, says so" {
  mkdir -p "$HOME/nowhere"
  cd "$HOME/nowhere"
  run vhosty worktree add x
  [ "$status" -ne 0 ]
  assert_contains "$output" "isn't inside a site"
}

# ---------------------------------------------------------------- hostile names

@test "hostile branch names reach no shell and no SQL" {
  repo_site ledger "$MYSQL_ENV"
  services_on
  cd "$PARKED/ledger"
  # All legal to git. A file named pwned appearing anywhere means one was run.
  i=0
  for b in 'a;touch${IFS}pwned' 'b$(touch${IFS}pwned)' 'c`touch${IFS}pwned`' "d'quote" 'e"quote' 'f|touch${IFS}pwned' 'g&&touch${IFS}pwned'; do
    i=$((i + 1))
    git -C "$PARKED/ledger" check-ref-format --branch "$b" >/dev/null
    run vhosty worktree add "$b"
    [ "$status" -eq 0 ] || { printf 'branch %s:\n%s\n' "$b" "$output" >&2; false; }
    [ "$(git -C "$PARKED/ledger" for-each-ref --format='%(refname:short)' "refs/heads/$b")" = "$b" ]
  done
  [ "$i" -eq 7 ]
  [ -z "$(find "$HOME" "$PARKED" -name 'pwned*' 2>/dev/null)" ]
  # Each became a plain name, in the config by value, and plain in SQL
  for f in "$VHOSTY_DIR"/sites/*.conf; do
    n="$(basename "$f" .conf)"
    vh valid_name "$n"
    vh worktree_db_name_ok "$(conf_value "$n" SITE_WT_DB_NAME)"
  done
  [ "$(conf_value a-touch-ifs-pwned--ledger SITE_WT_BRANCH)" = 'a;touch${IFS}pwned' ]
  refute_contains "$(cat "$HOME/sql.log")" "pwned;"
  refute_contains "$(cat "$HOME/sql.log")" 'touch$'
  refute_contains "$(cat "$HOME/sql.log")" "quote'"
  refute_contains "$(cat "$VHOSTY_DIR/Caddyfile")" 'touch$'
}

@test "branch names git refuses are refused before anything happens" {
  repo_site ledger
  cd "$PARKED/ledger"
  for b in '-rf' '--force' 'a b' 'a..b' '@{-1}' 'x~1'; do
    run vhosty worktree add -- "$b"
    [ "$status" -ne 0 ] || { echo "accepted: $b" >&2; false; }
  done
  run vhosty worktree add -rf
  [ "$status" -ne 0 ]
  assert_contains "$output" "Unknown option"
  [ ! -e "$VHOSTY_DIR/worktrees" ]
  [ "$(git -C "$PARKED/ledger" for-each-ref refs/heads | wc -l | tr -d ' ')" = 1 ]
}

@test "a hostile folder name (detached worktree) reaches no shell or SQL" {
  repo_site ledger "$MYSQL_ENV"
  services_on
  d="$HOME/w/a;touch \$(touch pwned) 'x"
  mkdir -p "$HOME/w"
  git -C "$PARKED/ledger" worktree add -q --detach "$d"
  cd "$d"
  run vhosty worktree link
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [ -z "$(find "$HOME" -name 'pwned*' 2>/dev/null)" ]
  n="$(ls "$VHOSTY_DIR/sites" | sed 's/\.conf$//' | grep -- '--ledger')"
  vh valid_name "$n"
  [ "$(conf_value "$n" SITE_PATH)" = "$(pwd -P)" ]
  refute_contains "$(cat "$HOME/sql.log")" "pwned;"
}

@test "passwords stay off command lines and out of what's printed" {
  repo_site ledger "$MYSQL_ENV"
  services_on
  mysql_db ledger
  cd "$PARKED/ledger"
  run vhosty worktree add feature/x --copy-db
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  refute_contains "$output" "hunter2secret"
  refute_contains "$(cat "$HOME/docker.log")" "hunter2secret"
  refute_contains "$(cat "$HOME/dump.log")" "hunter2secret"
  # A URL with a password in it is shared, and isn't printed either
  repo_site other 'DB_CONNECTION=mysql
DB_URL=mysql://u:hunter2secret@db.example.com/x'
  cd "$PARKED/other"
  run vhosty worktree add y
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  refute_contains "$output" "hunter2secret"
  assert_contains "$output" "SHARES"
}

# ---------------------------------------------------------------- MySQL

@test "mysql on the docker service: a new empty database, recorded" {
  repo_site ledger "$MYSQL_ENV"
  services_on
  mysql_db ledger
  cd "$PARKED/ledger"
  run vhosty worktree add feature/x
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [ -e "$HOME/db/mysql/wt_feature_x__ledger" ]
  [ ! -s "$HOME/db/mysql/wt_feature_x__ledger" ]
  assert_contains "$(cat "$HOME/sql.log")" 'CREATE DATABASE `wt_feature_x__ledger`'
  [ "$(conf_value feature-x--ledger SITE_WT_DB_KIND)" = mysql ]
  [ "$(conf_value feature-x--ledger SITE_WT_DB_SERVICE)" = mysql ]
  [ "$(conf_value feature-x--ledger SITE_WT_DB_NAME)" = wt_feature_x__ledger ]
  [ "$(cat "$HOME/db/mysql/ledger")" = "row of ledger" ]
  [ ! -e "$HOME/dump.log" ]
}

@test "mysql: --copy-db dumps the parent in one transaction, read only, into the new one" {
  repo_site ledger "$MYSQL_ENV"
  services_on
  mysql_db ledger
  cd "$PARKED/ledger"
  run vhosty worktree add feature/x --copy-db
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  assert_contains "$(cat "$HOME/db/mysql/wt_feature_x__ledger")" "row of ledger"
  [ "$(cat "$HOME/db/mysql/ledger")" = "row of ledger" ]
  dump="$(cat "$HOME/dump.log")"
  assert_contains "$dump" "--single-transaction"
  # --databases would put a USE ledger in the dump, aimed at the parent
  refute_contains "$dump" "--databases"
  refute_contains "$(cat "$HOME/sql.log")" "load into ledger"
  refute_contains "$output" "php artisan migrate --seed"
}

@test "mysql: a dump that dies halfway isn't taken for a copy, and leaves it empty" {
  repo_site ledger "$MYSQL_ENV"
  services_on
  mysql_db ledger
  touch "$HOME/dump-fails"
  cd "$PARKED/ledger"
  run vhosty worktree add feature/x --copy-db
  [ "$status" -ne 0 ]
  assert_contains "$output" "copying ledger failed"
  [ -e "$HOME/db/mysql/wt_feature_x__ledger" ]
  [ ! -s "$HOME/db/mysql/wt_feature_x__ledger" ]
  [ "$(cat "$HOME/db/mysql/ledger")" = "row of ledger" ]
  [ -f "$VHOSTY_DIR/sites/feature-x--ledger.conf" ]
}

@test "mysql: an app user other than root gets access to the new database" {
  repo_site ledger "${MYSQL_ENV/DB_USERNAME=root/DB_USERNAME=ledger_app}"
  services_on
  cd "$PARKED/ledger"
  run vhosty worktree add feature/x
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  assert_contains "$(cat "$HOME/sql.log")" "where User = 'ledger_app'"
  assert_contains "$(cat "$HOME/sql.log")" 'GRANT ALL PRIVILEGES ON `wt_feature_x__ledger`.*'
}

@test "mysql: a hostile DB_USERNAME reaches no SQL" {
  repo_site ledger "${MYSQL_ENV/DB_USERNAME=root/DB_USERNAME=x\'; DROP DATABASE ledger; --}"
  services_on
  cd "$PARKED/ledger"
  run vhosty worktree add feature/x
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  refute_contains "$(cat "$HOME/sql.log")" "DROP DATABASE"
  assert_contains "$output" "DB_USERNAME isn't a plain name"
}

@test "mysql: a hostile DB_DATABASE in the parent is refused for --copy-db" {
  repo_site ledger "${MYSQL_ENV/DB_DATABASE=ledger/DB_DATABASE=--all-databases}"
  services_on
  cd "$PARKED/ledger"
  run vhosty worktree add feature/x --copy-db
  [ "$status" -ne 0 ]
  assert_contains "$output" "isn't a plain database name"
  [ ! -e "$HOME/dump.log" ]
  [ ! -e "$VHOSTY_DIR/worktrees" ]
}

@test "mysql: a database of that name already there is refused, not adopted" {
  repo_site ledger "$MYSQL_ENV"
  services_on
  mysql_db wt_feature_x__ledger
  cd "$PARKED/ledger"
  run vhosty worktree add feature/x
  [ "$status" -ne 0 ]
  assert_contains "$output" "already on mysql"
  assert_contains "$output" "Nothing changed"
  [ ! -e "$VHOSTY_DIR/worktrees" ]
  ! git -C "$PARKED/ledger" show-ref --verify --quiet refs/heads/feature/x
  [ "$(cat "$HOME/db/mysql/wt_feature_x__ledger")" = "row of wt_feature_x__ledger" ]
}

@test "mysql: creating it fails: reported, the .env doesn't fall back to the parent's" {
  repo_site ledger "$MYSQL_ENV"
  services_on
  touch "$HOME/create-fails"
  cd "$PARKED/ledger"
  run vhosty worktree add feature/x
  [ "$status" -ne 0 ]
  assert_contains "$output" "couldn't create"
  [ "$(vh worktree_env_get "$VHOSTY_DIR/worktrees/ledger/feature-x/.env" DB_DATABASE)" = "wt_feature_x__ledger" ]
  [ -z "$(conf_value feature-x--ledger SITE_WT_DB_NAME)" ]
}

@test "mysql: a service that's down stops it, rather than sharing the database later" {
  repo_site ledger "$MYSQL_ENV"
  services_on
  sed -i.bak 's/"State":"running"/"State":"exited"/' "$HOME/ps.json"
  cd "$PARKED/ledger"
  run vhosty worktree add feature/x
  [ "$status" -ne 0 ]
  assert_contains "$output" "isn't running"
  [ ! -e "$VHOSTY_DIR/worktrees" ]
}

@test "mysql: compose that can't be read stops it, rather than sharing the database" {
  repo_site ledger "$MYSQL_ENV"
  services_on
  touch "$HOME/compose-fails"
  cd "$PARKED/ledger"
  run vhosty worktree add feature/x
  [ "$status" -ne 0 ]
  assert_contains "$output" "Can't read the docker services"
  [ ! -e "$VHOSTY_DIR/worktrees" ]
}

# ---------------------------------------------------------------- Postgres

@test "postgres on the docker service: a new empty database, owned by the app's user, recorded" {
  repo_site ledger "$PG_ENV"
  services_on
  cd "$PARKED/ledger"
  run vhosty worktree add feature/x
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [ -e "$HOME/db/postgres/wt_feature_x__ledger" ]
  assert_contains "$(cat "$HOME/sql.log")" 'CREATE DATABASE "wt_feature_x__ledger" OWNER "ledger_app"'
  [ "$(conf_value feature-x--ledger SITE_WT_DB_KIND)" = postgres ]
  [ "$(conf_value feature-x--ledger SITE_WT_DB_SERVICE)" = postgres ]
  assert_contains "$output" "php artisan migrate --seed"
}

@test "postgres: --copy-db loads a plain dump into the new one, as the app's role" {
  repo_site ledger "$PG_ENV"
  services_on
  pg_db ledger
  cd "$PARKED/ledger"
  run vhosty worktree add feature/x --copy-db
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  new="$(cat "$HOME/db/postgres/wt_feature_x__ledger")"
  assert_contains "$new" 'SET ROLE "ledger_app"'
  assert_contains "$new" "row of ledger"
  [ "$(cat "$HOME/db/postgres/ledger")" = "row of ledger" ]
  dump="$(cat "$HOME/dump.log")"
  assert_contains "$dump" "--no-owner"
  refute_contains "$dump" "--clean"
  refute_contains "$dump" "--create"
  refute_contains "$(cat "$HOME/sql.log")" "load into ledger"
}

@test "postgres: a dump that dies isn't taken for a copy" {
  repo_site ledger "$PG_ENV"
  services_on
  pg_db ledger
  touch "$HOME/dump-fails"
  cd "$PARKED/ledger"
  run vhosty worktree add feature/x --copy-db
  [ "$status" -ne 0 ]
  assert_contains "$output" "copying ledger failed"
  [ "$(cat "$HOME/db/postgres/ledger")" = "row of ledger" ]
}

@test "postgres: remove drops only the recorded database, after asking" {
  repo_site ledger "$PG_ENV"
  services_on
  pg_db ledger
  cd "$PARKED/ledger"
  run vhosty worktree add feature/x
  [ "$status" -eq 0 ]
  run vhosty worktree remove feature-x--ledger --yes
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [ ! -e "$HOME/db/postgres/wt_feature_x__ledger" ]
  [ -e "$HOME/db/postgres/ledger" ]
  assert_contains "$(cat "$HOME/sql.log")" 'DROP DATABASE "wt_feature_x__ledger"'
}

# ---------------------------------------------------------------- sqlite

@test "sqlite: an empty file per worktree, recorded, and DB_DATABASE set" {
  repo_site ledger "$SQLITE_ENV"
  echo data >"$PARKED/ledger/database/database.sqlite"
  before="$(cksum <"$PARKED/ledger/database/database.sqlite")"
  cd "$PARKED/ledger"
  run vhosty worktree add feature/x
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  real="$(cd "$VHOSTY_DIR/worktrees/ledger/feature-x" && pwd -P)"
  [ -f "$real/database/database.sqlite" ]
  [ ! -s "$real/database/database.sqlite" ]
  [ "$(vh worktree_env_get "$real/.env" DB_DATABASE)" = "$real/database/database.sqlite" ]
  [ "$(conf_value feature-x--ledger SITE_WT_DB_KIND)" = sqlite ]
  [ "$(conf_value feature-x--ledger SITE_WT_DB_NAME)" = "$real/database/database.sqlite" ]
  [ "$(cksum <"$PARKED/ledger/database/database.sqlite")" = "$before" ]
  assert_contains "$output" "php artisan migrate --seed"
}

@test "sqlite: --copy-db copies the parent's file, a path in .env included" {
  repo_site ledger 'DB_CONNECTION=sqlite
DB_DATABASE=database/custom.sqlite'
  echo data >"$PARKED/ledger/database/custom.sqlite"
  cd "$PARKED/ledger"
  run vhosty worktree add feature/x --copy-db
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [ "$(cat "$VHOSTY_DIR/worktrees/ledger/feature-x/database/database.sqlite")" = data ]
  [ "$(cat "$PARKED/ledger/database/custom.sqlite")" = data ]
}

@test "sqlite: --copy-db uses sqlite3's backup, read only, when there's a sqlite3" {
  repo_site ledger "$SQLITE_ENV"
  echo data >"$PARKED/ledger/database/database.sqlite"
  stub sqlite3 'printf "%s\n" "sqlite3 $*" >>"$HOME/sqlite3.log"; echo copied >"database.sqlite"'
  cd "$PARKED/ledger"
  run vhosty worktree add feature/x --copy-db
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  assert_contains "$(cat "$HOME/sqlite3.log")" "-readonly"
  assert_contains "$(cat "$HOME/sqlite3.log")" ".backup database.sqlite"
  [ "$(cat "$VHOSTY_DIR/worktrees/ledger/feature-x/database/database.sqlite")" = copied ]
}

@test "sqlite: --copy-db with no file to copy stops before anything changes" {
  repo_site ledger "$SQLITE_ENV"
  cd "$PARKED/ledger"
  run vhosty worktree add feature/x --copy-db
  [ "$status" -ne 0 ]
  assert_contains "$output" "isn't there"
  [ ! -e "$VHOSTY_DIR/worktrees" ]
}

@test "sqlite: a file the checkout already has isn't vhosty's, and survives remove's db step" {
  repo_site ledger "$SQLITE_ENV"
  git -C "$PARKED/ledger" worktree add -q "$HOME/wt" -b feature/x
  mkdir -p "$HOME/wt/database"
  echo agents-work >"$HOME/wt/database/database.sqlite"
  cd "$HOME/wt"
  run vhosty worktree link
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [ -z "$(conf_value feature-x--ledger SITE_WT_DB_KIND)" ]
  run vhosty worktree remove feature-x--ledger --yes
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [ "$(cat "$HOME/wt/database/database.sqlite")" = agents-work ]
}

@test "sqlite: remove on an adopted worktree deletes the recorded file only" {
  repo_site ledger "$SQLITE_ENV"
  git -C "$PARKED/ledger" worktree add -q "$HOME/wt" -b feature/x
  cd "$HOME/wt"
  run vhosty worktree link
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [ -f "$HOME/wt/database/database.sqlite" ]
  run vhosty worktree remove feature-x--ledger --yes
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [ ! -e "$HOME/wt/database/database.sqlite" ]
  [ -d "$HOME/wt/public" ]
}

@test "sqlite: --keep-db on a created worktree keeps the file, outside the folder that goes" {
  repo_site ledger "$SQLITE_ENV"
  cd "$PARKED/ledger"
  run vhosty worktree add feature/x
  [ "$status" -eq 0 ]
  echo migrated >"$VHOSTY_DIR/worktrees/ledger/feature-x/database/database.sqlite"
  run vhosty worktree remove feature-x--ledger --keep-db
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [ ! -e "$VHOSTY_DIR/worktrees/ledger/feature-x" ]
  [ "$(cat "$VHOSTY_DIR/worktrees/feature-x--ledger.sqlite")" = migrated ]
  assert_contains "$output" "feature-x--ledger.sqlite"
}

@test "sqlite in memory: nothing to set up" {
  repo_site ledger 'DB_CONNECTION=sqlite
DB_DATABASE=:memory:'
  cd "$PARKED/ledger"
  run vhosty worktree add feature/x
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [ "$(vh worktree_env_get "$VHOSTY_DIR/worktrees/ledger/feature-x/.env" DB_DATABASE)" = ":memory:" ]
  [ -z "$(conf_value feature-x--ledger SITE_WT_DB_KIND)" ]
}

# ---------------------------------------------------------------- shared databases

shared_case() { # shared_case ENV_TEXT
  repo_site ledger "$1"
  services_on
  cd "$PARKED/ledger"
  run vhosty worktree add feature/x
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  assert_contains "$output" "SHARES ledger's database"
  [ "$(vh worktree_env_get "$VHOSTY_DIR/worktrees/ledger/feature-x/.env" DB_DATABASE)" = "$(vh worktree_env_get "$PARKED/ledger/.env" DB_DATABASE)" ]
  [ -z "$(conf_value feature-x--ledger SITE_WT_DB_KIND)" ]
  [ ! -e "$HOME/sql.log" ]
}

@test "a remote database host is left alone, and the warning is plain" {
  shared_case "${MYSQL_ENV/DB_HOST=127.0.0.1/DB_HOST=db.example.com}"
  refute_contains "$output" "php artisan migrate --seed"
}

@test "a local port no vhosty service publishes is left alone" {
  shared_case "${MYSQL_ENV/DB_PORT=3306/DB_PORT=3307}"
}

@test "a port published by a service of another kind is left alone" {
  shared_case "${MYSQL_ENV/DB_PORT=3306/DB_PORT=6379}"
}

@test "a socket connection is left alone" {
  shared_case "$MYSQL_ENV
DB_SOCKET=/var/run/mysqld/mysqld.sock"
}

@test "a database URL is left alone" {
  shared_case "$MYSQL_ENV
DB_URL=mysql://u:p@127.0.0.1/ledger"
}

@test "a connection vhosty doesn't manage is left alone" {
  shared_case 'DB_CONNECTION=sqlsrv
DB_DATABASE=ledger'
}

@test "with no docker services set up, a local database is left alone" {
  repo_site ledger "$MYSQL_ENV"
  cd "$PARKED/ledger"
  run vhosty worktree add feature/x
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  assert_contains "$output" "SHARES ledger's database"
  [ ! -e "$HOME/docker.log" ]
}

@test "--copy-db on a shared database says it did nothing" {
  repo_site ledger "${MYSQL_ENV/DB_HOST=127.0.0.1/DB_HOST=db.example.com}"
  cd "$PARKED/ledger"
  run vhosty worktree add feature/x --copy-db
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  assert_contains "$output" "--copy-db did nothing"
  [ ! -e "$HOME/dump.log" ]
}

# ---------------------------------------------------------------- PHP

@test "PHP: inherits the pin, settings and extensions, but never Octane" {
  repo_site ledger
  site_conf ledger "SITE_PATH=$PARKED/ledger
SITE_PHP=8.3
SITE_INI='memory_limit=2G'
SITE_EXT='redis'
SITE_OCTANE=21000
SITE_OCTANE_WORKERS=4"
  cd "$PARKED/ledger"
  run vhosty worktree add feature/x
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [ "$(conf_value feature-x--ledger SITE_PHP)" = 8.3 ]
  [ "$(conf_value feature-x--ledger SITE_INI)" = memory_limit=2G ]
  [ "$(conf_value feature-x--ledger SITE_EXT)" = redis ]
  [ -z "$(conf_value feature-x--ledger SITE_OCTANE)" ]
  [ -z "$(conf_value feature-x--ledger SITE_OCTANE_WORKERS)" ]
  [ "$(conf_value ledger SITE_OCTANE)" = 21000 ]
  assert_contains "$output" "vhosty octane on feature-x--ledger"
  block="$(sed -n '/@site_feature-x--ledger host/,/^	}/p' "$VHOSTY_DIR/Caddyfile")"
  assert_contains "$block" "php_fastcgi"
  assert_contains "$block" "site-feature-x--ledger.sock"
  refute_contains "$block" "21000"
}

@test "Octane on a worktree site: the -- name works as a service, and the record stays" {
  repo_site ledger "OCTANE_SERVER=frankenphp
DB_CONNECTION=sqlite"
  mkdir -p "$PARKED/ledger/vendor/laravel/octane"
  cd "$PARKED/ledger"
  run vhosty worktree add feature/x --no-install
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  wt="$VHOSTY_DIR/worktrees/ledger/feature-x"
  mkdir -p "$wt/vendor/laravel/octane"
  echo '{}' >"$wt/vendor/laravel/octane/composer.json"
  printf '#!/bin/sh\n' >"$wt/frankenphp"; chmod +x "$wt/frankenphp"
  run vhosty octane on feature-x--ledger
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [ -n "$(conf_value feature-x--ledger SITE_OCTANE)" ]
  [ "$(conf_value feature-x--ledger SITE_WT_KIND)" = created ]
  assert_contains "$(cat "$VHOSTY_DIR/Caddyfile")" "# Site: feature-x--ledger → $(cd "$wt" && pwd -P) (Laravel Octane"
  [ "$(vh svc_resolve octane-feature-x--ledger)" = octane-feature-x--ledger ]
  [ "$(linux unit_of octane-feature-x--ledger)" = vhosty-octane-feature-x--ledger.service ]
  mkdir -p "$XDG_CONFIG_HOME/systemd/user"
  linux write_octane_unit feature-x--ledger
  rm "$VHOSTY_DIR/sites/feature-x--ledger.conf"
  [ "$(linux sd_stale_octane)" = feature-x--ledger ]
}

@test "the same branch can be added again after remove" {
  repo_site ledger "$MYSQL_ENV"
  services_on
  cd "$PARKED/ledger"
  run vhosty worktree add feature/x
  [ "$status" -eq 0 ]
  run vhosty worktree remove feature-x--ledger --yes
  [ "$status" -eq 0 ]
  run vhosty worktree add feature/x
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  assert_contains "$output" "existing branch"
  [ -e "$HOME/db/mysql/wt_feature_x__ledger" ]
}

@test "other commands keep the record: a pin doesn't lose the database" {
  repo_site ledger "$MYSQL_ENV"
  services_on
  cd "$PARKED/ledger"
  run vhosty worktree add feature/x
  [ "$status" -eq 0 ]
  vh eval 'site_load feature-x--ledger; SITE_PHP=8.2; site_save feature-x--ledger'
  [ "$(conf_value feature-x--ledger SITE_PHP)" = 8.2 ]
  [ "$(conf_value feature-x--ledger SITE_WT_DB_NAME)" = wt_feature_x__ledger ]
  [ "$(conf_value feature-x--ledger SITE_WT_KIND)" = created ]
}

@test "a site with no worktree keeps a config with no worktree lines" {
  mkdir -p "$HOME/p"
  vh cmd_link "$HOME/p" --name plain
  refute_contains "$(conf plain)" "SITE_WT_"
}

# ---------------------------------------------------------------- composer

@test "composer runs in the worktree, through the shim" {
  repo_site ledger
  echo '{}' >"$PARKED/ledger/composer.json"
  git -C "$PARKED/ledger" add -A; git -C "$PARKED/ledger" commit -qm c
  cd "$PARKED/ledger"
  run vhosty worktree add feature/x
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  log="$(cat "$HOME/composer.log")"
  assert_contains "$log" "composer install --no-interaction (in $(cd "$VHOSTY_DIR/worktrees/ledger/feature-x" && pwd -P))"
  assert_contains "$log" "php=$VHOSTY_DIR/bin/php"
}

@test "composer failing is reported, and the site stays" {
  repo_site ledger
  echo '{}' >"$PARKED/ledger/composer.json"
  git -C "$PARKED/ledger" add -A; git -C "$PARKED/ledger" commit -qm c
  touch "$HOME/composer-fails"
  cd "$PARKED/ledger"
  run vhosty worktree add feature/x
  [ "$status" -ne 0 ]
  assert_contains "$output" "composer install failed"
  [ -f "$VHOSTY_DIR/sites/feature-x--ledger.conf" ]
  assert_contains "$(cat "$VHOSTY_DIR/Caddyfile")" "@site_feature-x--ledger"
}

@test "--no-install skips composer, and says what's left to do; npm is only ever a next step" {
  repo_site ledger
  echo '{}' >"$PARKED/ledger/composer.json"
  echo '{}' >"$PARKED/ledger/package-lock.json"
  git -C "$PARKED/ledger" add -A; git -C "$PARKED/ledger" commit -qm c
  stub npm 'touch "$HOME/npm-ran"'
  cd "$PARKED/ledger"
  run vhosty worktree add feature/x --no-install
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [ ! -e "$HOME/composer.log" ]
  [ ! -e "$HOME/npm-ran" ]
  assert_contains "$output" "composer install"
  assert_contains "$output" "npm ci"
}

@test "no composer.json, no composer" {
  repo_site ledger
  cd "$PARKED/ledger"
  run vhosty worktree add feature/x
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/composer.log" ]
}

# ---------------------------------------------------------------- link

@test "link: adopts a worktree, like one of T3's, and refuses to redo it" {
  repo_site ledger "$MYSQL_ENV"
  services_on
  git -C "$PARKED/ledger" worktree add -q "$HOME/t3/t3-abc" -b t3/thing
  cd "$HOME/t3/t3-abc"
  run vhosty worktree link
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [ "$(conf_value t3-thing--ledger SITE_WT_KIND)" = adopted ]
  [ "$(conf_value t3-thing--ledger SITE_WT_PARENT)" = ledger ]
  [ "$(conf_value t3-thing--ledger SITE_WT_DB_NAME)" = wt_t3_thing__ledger ]
  [ "$(vh worktree_env_get "$HOME/t3/t3-abc/.env" DB_DATABASE)" = wt_t3_thing__ledger ]
  # again: nothing new
  rm "$HOME/sql.log"
  run vhosty worktree link "$HOME/t3/t3-abc"
  [ "$status" -eq 0 ]
  assert_contains "$output" "already the worktree site"
  [ ! -e "$HOME/sql.log" ]
}

@test "link: a detached worktree uses its folder name" {
  repo_site ledger
  git -C "$PARKED/ledger" worktree add -q --detach "$HOME/t3/t3-31715911"
  run vhosty worktree link "$HOME/t3/t3-31715911"
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [ -f "$VHOSTY_DIR/sites/t3-31715911--ledger.conf" ]
  [ -z "$(conf_value t3-31715911--ledger SITE_WT_BRANCH)" ]
}

@test "link: refuses the main checkout" {
  repo_site ledger
  cd "$PARKED/ledger"
  run vhosty worktree link
  [ "$status" -ne 0 ]
  assert_contains "$output" "main checkout"
}

@test "link: refuses a folder that isn't in a repository" {
  mkdir -p "$HOME/plain"
  run vhosty worktree link "$HOME/plain"
  [ "$status" -ne 0 ]
  assert_contains "$output" "isn't in a git repository"
}

@test "link: refuses when the parent isn't a site" {
  mkdir -p "$HOME/repo"
  git -C "$HOME/repo" init -q
  git -C "$HOME/repo" commit -q --allow-empty -m x
  git -C "$HOME/repo" worktree add -q "$HOME/wt" -b x
  run vhosty worktree link "$HOME/wt"
  [ "$status" -ne 0 ]
  assert_contains "$output" "isn't a site"
  assert_contains "$output" "vhosty link"
  [ -z "$(ls "$VHOSTY_DIR/sites")" ]
}

@test "link: refuses a worktree that's already a plain linked site" {
  repo_site ledger
  git -C "$PARKED/ledger" worktree add -q "$HOME/wt" -b x
  vh cmd_link "$HOME/wt" --name plainlink >/dev/null
  run vhosty worktree link "$HOME/wt"
  [ "$status" -ne 0 ]
  assert_contains "$output" "already the site 'plainlink'"
}

@test "link: works with spaces in the path, and through a symlink" {
  repo_site ledger "$SQLITE_ENV"
  git -C "$PARKED/ledger" worktree add -q "$HOME/my trees/one" -b one
  ln -s "$HOME/my trees/one" "$HOME/shortcut"
  cd "$HOME/shortcut"
  run vhosty worktree link
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  real="$(cd "$HOME/my trees/one" && pwd -P)"
  [ "$(conf_value one--ledger SITE_PATH)" = "$real" ]
  [ "$(conf_value one--ledger SITE_WT_ALIAS)" = "$HOME/shortcut" ]
  [ "$(vh worktree_env_get "$real/.env" DB_DATABASE)" = "$real/database/database.sqlite" ]
  assert_contains "$(cat "$VHOSTY_DIR/Caddyfile")" "root * \"$real/public\""
  # the site is found from either spelling
  [ "$(vh site_from_dir "$HOME/shortcut")" = one--ledger ]
  [ "$(vh site_from_dir "$real")" = one--ledger ]
}

@test "link: finds the parent when the parked folder is itself reached through a symlink" {
  mkdir -p "$HOME/real-sites"
  rmdir "$PARKED"
  ln -s "$HOME/real-sites" "$PARKED"
  repo_site ledger
  git -C "$PARKED/ledger" worktree add -q "$HOME/wt" -b x
  run vhosty worktree link "$HOME/wt"
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [ "$(conf_value x--ledger SITE_WT_PARENT)" = ledger ]
}

@test "link: a linked parent is found too" {
  mkdir -p "$HOME/Projects"
  repo_site ledger
  mv "$PARKED/ledger" "$HOME/Projects/ledger"
  vh cmd_link "$HOME/Projects/ledger" --name money >/dev/null
  git -C "$HOME/Projects/ledger" worktree add -q "$HOME/wt" -b x
  run vhosty worktree link "$HOME/wt"
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [ "$(conf_value x--money SITE_WT_PARENT)" = money ]
}

@test "link: a .env that's a symlink to the parent's is replaced; the parent's isn't touched" {
  repo_site ledger "$MYSQL_ENV"
  services_on
  before="$(cksum <"$PARKED/ledger/.env")"
  git -C "$PARKED/ledger" worktree add -q "$HOME/wt" -b x
  ln -s "$PARKED/ledger/.env" "$HOME/wt/.env"
  run vhosty worktree link "$HOME/wt"
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [ ! -L "$HOME/wt/.env" ]
  [ "$(cksum <"$PARKED/ledger/.env")" = "$before" ]
  [ "$(vh worktree_env_get "$HOME/wt/.env" DB_DATABASE)" = wt_x__ledger ]
}

@test "link: a copied .env naming the parent's database gets its own" {
  repo_site ledger "$MYSQL_ENV"
  services_on
  git -C "$PARKED/ledger" worktree add -q "$HOME/wt" -b x
  cp "$PARKED/ledger/.env" "$HOME/wt/.env"
  run vhosty worktree link "$HOME/wt"
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [ "$(vh worktree_env_get "$HOME/wt/.env" DB_DATABASE)" = wt_x__ledger ]
  assert_contains "$output" "its own .env"
}

@test "link: a .env with a database of its own keeps it, and nothing's recorded" {
  repo_site ledger "$MYSQL_ENV"
  services_on
  git -C "$PARKED/ledger" worktree add -q "$HOME/wt" -b x
  sed 's/^DB_DATABASE=.*/DB_DATABASE=agents_own/' "$PARKED/ledger/.env" >"$HOME/wt/.env"
  run vhosty worktree link "$HOME/wt"
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [ "$(vh worktree_env_get "$HOME/wt/.env" DB_DATABASE)" = agents_own ]
  [ "$(vh worktree_env_get "$HOME/wt/.env" APP_URL)" = "https://x--ledger.test.example" ]
  [ -z "$(conf_value x--ledger SITE_WT_DB_NAME)" ]
  [ ! -e "$HOME/sql.log" ]
}

@test "link: warns about a cached config, which still names the old database" {
  repo_site ledger
  git -C "$PARKED/ledger" worktree add -q "$HOME/wt" -b x
  mkdir -p "$HOME/wt/bootstrap/cache"
  echo '<?php' >"$HOME/wt/bootstrap/cache/config.php"
  run vhosty worktree link "$HOME/wt"
  [ "$status" -eq 0 ]
  assert_contains "$output" "config:clear"
}

# ---------------------------------------------------------------- env warnings

@test "warns about settings that still name the parent's address, without their values" {
  repo_site ledger 'APP_URL=https://ledger.test.example
SESSION_DOMAIN=ledger.test.example
OTHER=not-ledger.test.example
SECRET=abc
DB_CONNECTION=sqlite'
  cd "$PARKED/ledger"
  run vhosty worktree add feature/x
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  assert_contains "$output" "still name ledger's address: SESSION_DOMAIN"
  refute_contains "$output" "SESSION_DOMAIN OTHER"
  refute_contains "$output" "APP_URL SESSION"
}

@test "warns when Redis would be shared with the parent" {
  repo_site ledger 'DB_CONNECTION=sqlite
CACHE_STORE=redis'
  cd "$PARKED/ledger"
  run vhosty worktree add feature/x
  [ "$status" -eq 0 ]
  assert_contains "$output" "REDIS_PREFIX"
}

# ---------------------------------------------------------------- remove

@test "remove (created): the folder goes with git, the branch and parent stay, the database is dropped" {
  repo_site ledger "$MYSQL_ENV"
  services_on
  mysql_db ledger
  cd "$PARKED/ledger"
  run vhosty worktree add feature/x
  [ "$status" -eq 0 ]
  dir="$VHOSTY_DIR/worktrees/ledger/feature-x"
  run vhosty worktree remove feature-x--ledger --yes
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [ ! -e "$dir" ]
  [ ! -e "$VHOSTY_DIR/sites/feature-x--ledger.conf" ]
  [ ! -e "$HOME/db/mysql/wt_feature_x__ledger" ]
  [ -e "$HOME/db/mysql/ledger" ]
  git -C "$PARKED/ledger" show-ref --verify --quiet refs/heads/feature/x
  refute_contains "$(git -C "$PARKED/ledger" worktree list)" "feature-x"
  refute_contains "$(cat "$VHOSTY_DIR/Caddyfile")" "feature-x--ledger"
  refute_contains "$(cat "$HOME/sql.log")" "DROP DATABASE \`ledger\`"
}

@test "remove: uncommitted work stops it, and nothing at all is removed" {
  repo_site ledger "$MYSQL_ENV"
  services_on
  cd "$PARKED/ledger"
  run vhosty worktree add feature/x
  [ "$status" -eq 0 ]
  dir="$VHOSTY_DIR/worktrees/ledger/feature-x"
  echo work >"$dir/work.php"
  run vhosty worktree remove feature-x--ledger --yes
  [ "$status" -ne 0 ]
  assert_contains "$output" "work.php"
  assert_contains "$output" "Nothing was removed"
  [ "$(cat "$dir/work.php")" = work ]
  [ -f "$VHOSTY_DIR/sites/feature-x--ledger.conf" ]
  [ -e "$HOME/db/mysql/wt_feature_x__ledger" ]
  refute_contains "$(cat "$HOME/sql.log")" "DROP DATABASE"
  refute_contains "$(cat "$HOME/docker.log")" "--force"
}

@test "remove (adopted): the folder stays, and the site and vhosty's database go" {
  repo_site ledger "$MYSQL_ENV"
  services_on
  mysql_db ledger
  git -C "$PARKED/ledger" worktree add -q "$HOME/t3/wt" -b x
  run vhosty worktree link "$HOME/t3/wt"
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  echo work >"$HOME/t3/wt/uncommitted.php"
  run vhosty worktree remove x--ledger --yes
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [ "$(cat "$HOME/t3/wt/uncommitted.php")" = work ]
  [ -f "$HOME/t3/wt/.env" ]
  assert_contains "$(git -C "$PARKED/ledger" worktree list)" "$HOME/t3/wt"
  [ ! -e "$VHOSTY_DIR/sites/x--ledger.conf" ]
  [ ! -e "$HOME/db/mysql/wt_x__ledger" ]
  [ -e "$HOME/db/mysql/ledger" ]
  assert_contains "$output" "isn't vhosty's"
}

@test "remove: drops only what's recorded, whatever the .env says now" {
  repo_site ledger "$MYSQL_ENV"
  services_on
  mysql_db ledger
  mysql_db other_db
  git -C "$PARKED/ledger" worktree add -q "$HOME/wt" -b x
  run vhosty worktree link "$HOME/wt"
  [ "$status" -eq 0 ]
  sed -i.bak 's/^DB_DATABASE=.*/DB_DATABASE=other_db/' "$HOME/wt/.env"
  run vhosty worktree remove x--ledger --yes
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [ -e "$HOME/db/mysql/other_db" ]
  [ -e "$HOME/db/mysql/ledger" ]
  [ ! -e "$HOME/db/mysql/wt_x__ledger" ]
}

@test "remove: no record, no drop, even for a database with the name vhosty would use" {
  repo_site ledger "$MYSQL_ENV"
  services_on
  sed 's/^DB_DATABASE=.*/DB_DATABASE=wt_x__ledger/' "$PARKED/ledger/.env" >"$HOME/x"
  git -C "$PARKED/ledger" worktree add -q "$HOME/wt" -b x
  cp "$HOME/x" "$HOME/wt/.env"
  mysql_db wt_x__ledger
  run vhosty worktree link "$HOME/wt"
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [ -z "$(conf_value x--ledger SITE_WT_DB_NAME)" ]
  run vhosty worktree remove x--ledger --yes
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [ -e "$HOME/db/mysql/wt_x__ledger" ]
  refute_contains "$(cat "$HOME/sql.log")" "DROP DATABASE"
}

@test "remove: a record that names the parent's database, or any other, is refused" {
  repo_site ledger "$MYSQL_ENV"
  services_on
  mysql_db ledger
  mkdir -p "$HOME/wt"
  for bad in ledger mysql 'wt_x`; DROP DATABASE `ledger'; do
    site_conf x--ledger "SITE_PATH=$HOME/wt
SITE_LINKED=yes
SITE_WT_KIND=adopted
SITE_WT_PARENT=ledger
SITE_WT_REPO=$PARKED/ledger
SITE_WT_DB_KIND=mysql
SITE_WT_DB_SERVICE=mysql
SITE_WT_DB_NAME=$(printf '%q' "$bad")"
    run vhosty worktree remove x--ledger --yes
    [ "$status" -ne 0 ]
    assert_contains "$output" "Not dropping"
    [ -f "$VHOSTY_DIR/sites/x--ledger.conf" ]
  done
  [ ! -e "$HOME/sql.log" ] || refute_contains "$(cat "$HOME/sql.log")" "DROP"
  [ -e "$HOME/db/mysql/ledger" ]
  # Named like vhosty's, but it's what the parent uses now
  sed -i.bak 's/^DB_DATABASE=.*/DB_DATABASE=wt_mine/' "$PARKED/ledger/.env"
  mysql_db wt_mine
  site_conf x--ledger "SITE_PATH=$HOME/wt
SITE_LINKED=yes
SITE_WT_KIND=adopted
SITE_WT_PARENT=ledger
SITE_WT_REPO=$PARKED/ledger
SITE_WT_DB_KIND=mysql
SITE_WT_DB_SERVICE=mysql
SITE_WT_DB_NAME=wt_mine"
  run vhosty worktree remove x--ledger --yes
  [ "$status" -ne 0 ]
  assert_contains "$output" "is the database ledger's .env uses"
  [ -e "$HOME/db/mysql/wt_mine" ]
}

@test "remove: a sqlite record outside the worktree is refused" {
  repo_site ledger
  mkdir -p "$HOME/wt/public"
  echo data >"$HOME/precious.sqlite"
  for f in "$HOME/precious.sqlite" "$HOME/wt/../precious.sqlite"; do
    site_conf x--ledger "SITE_PATH=$HOME/wt
SITE_LINKED=yes
SITE_WT_KIND=adopted
SITE_WT_PARENT=ledger
SITE_WT_DB_KIND=sqlite
SITE_WT_DB_NAME=$f"
    run vhosty worktree remove x--ledger --yes
    [ "$status" -ne 0 ]
    assert_contains "$output" "Not deleting"
    [ -f "$HOME/precious.sqlite" ]
  done
}

@test "remove: won't touch a site that isn't a worktree" {
  mkdir -p "$HOME/p"
  vh cmd_link "$HOME/p" --name plain >/dev/null
  run vhosty worktree remove plain --yes
  [ "$status" -ne 0 ]
  assert_contains "$output" "isn't a worktree site"
  [ -f "$VHOSTY_DIR/sites/plain.conf" ]
  [ -d "$HOME/p" ]
  run vhosty worktree remove nosuch --yes
  [ "$status" -ne 0 ]
  run vhosty worktree remove 'x;y' --yes
  [ "$status" -ne 0 ]
}

# Runs cmd_worktree_remove with a terminal that answers: the question is logged
remove_answering() { # remove_answering yes|no NAME
  VHOSTY_SRC="$ROOT/bin/vhosty" bash -c 'source "$VHOSTY_SRC"; has_tty() { return 0; }
    confirm() { printf "%s\n" "$1" >>"$HOME/asked"; [ "$ANSWER" = yes ]; }
    trap cleanup_tmp EXIT; load_config; cmd_worktree_remove "$@"' vh "$2"
}

@test "remove: the confirmation names the database, and no means nothing's removed" {
  repo_site ledger "$MYSQL_ENV"
  services_on
  cd "$PARKED/ledger"
  run vhosty worktree add feature/x
  [ "$status" -eq 0 ]
  ANSWER=no run remove_answering no feature-x--ledger
  [ "$status" -eq 0 ]
  assert_contains "$(cat "$HOME/asked")" "wt_feature_x__ledger"
  assert_contains "$(cat "$HOME/asked")" "mysql"
  [ -d "$VHOSTY_DIR/worktrees/ledger/feature-x" ]
  [ -e "$HOME/db/mysql/wt_feature_x__ledger" ]
  [ -f "$VHOSTY_DIR/sites/feature-x--ledger.conf" ]
  ANSWER=yes run remove_answering yes feature-x--ledger
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/db/mysql/wt_feature_x__ledger" ]
}

@test "remove: with no terminal and no --yes, a database isn't dropped" {
  command -v setsid >/dev/null || skip "needs setsid to run without a terminal"
  repo_site ledger "$MYSQL_ENV"
  services_on
  cd "$PARKED/ledger"
  run vhosty worktree add feature/x
  [ "$status" -eq 0 ]
  run setsid -w bash "$ROOT/bin/vhosty" worktree remove feature-x--ledger
  [ "$status" -ne 0 ]
  assert_contains "$output" "--yes"
  [ -e "$HOME/db/mysql/wt_feature_x__ledger" ]
  [ -d "$VHOSTY_DIR/worktrees/ledger/feature-x" ]
}

@test "remove: --keep-db keeps it, asks nothing, and says how to drop it" {
  repo_site ledger "$MYSQL_ENV"
  services_on
  cd "$PARKED/ledger"
  run vhosty worktree add feature/x
  [ "$status" -eq 0 ]
  run vhosty worktree remove feature-x--ledger --keep-db
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [ -e "$HOME/db/mysql/wt_feature_x__ledger" ]
  [ ! -e "$VHOSTY_DIR/sites/feature-x--ledger.conf" ]
  assert_contains "$output" 'DROP DATABASE `wt_feature_x__ledger`'
}

@test "remove: a drop that fails is reported, the record stays, and running it again works" {
  repo_site ledger "$MYSQL_ENV"
  services_on
  cd "$PARKED/ledger"
  run vhosty worktree add feature/x
  [ "$status" -eq 0 ]
  touch "$HOME/drop-fails"
  run vhosty worktree remove feature-x--ledger --yes
  [ "$status" -ne 0 ]
  assert_contains "$output" "couldn't drop"
  assert_contains "$output" "wt_feature_x__ledger"
  [ -e "$HOME/db/mysql/wt_feature_x__ledger" ]
  [ "$(conf_value feature-x--ledger SITE_WT_DB_NAME)" = wt_feature_x__ledger ]
  rm "$HOME/drop-fails"
  run vhosty worktree remove feature-x--ledger --yes
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [ ! -e "$HOME/db/mysql/wt_feature_x__ledger" ]
  [ ! -e "$VHOSTY_DIR/sites/feature-x--ledger.conf" ]
}

@test "remove: a database service it can't reach stops it before anything's removed" {
  repo_site ledger "$MYSQL_ENV"
  services_on
  cd "$PARKED/ledger"
  run vhosty worktree add feature/x
  [ "$status" -eq 0 ]
  touch "$HOME/exec-fails"
  run vhosty worktree remove feature-x--ledger --yes
  [ "$status" -ne 0 ]
  assert_contains "$output" "Nothing removed"
  [ -d "$VHOSTY_DIR/worktrees/ledger/feature-x" ]
  [ -f "$VHOSTY_DIR/sites/feature-x--ledger.conf" ]
}

@test "remove: a database someone already dropped isn't an error" {
  repo_site ledger "$MYSQL_ENV"
  services_on
  cd "$PARKED/ledger"
  run vhosty worktree add feature/x
  [ "$status" -eq 0 ]
  rm "$HOME/db/mysql/wt_feature_x__ledger"
  run vhosty worktree remove feature-x--ledger --yes
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  assert_contains "$output" "already gone"
}

# ---------------------------------------------------------------- folder deleted underneath

@test "folder deleted by hand: remove still works, and drops the database" {
  repo_site ledger "$MYSQL_ENV"
  services_on
  cd "$PARKED/ledger"
  run vhosty worktree add feature/x
  [ "$status" -eq 0 ]
  git -C "$PARKED/ledger" worktree remove --force "$VHOSTY_DIR/worktrees/ledger/feature-x"
  run vhosty worktree remove feature-x--ledger --yes
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [ ! -e "$VHOSTY_DIR/sites/feature-x--ledger.conf" ]
  [ ! -e "$HOME/db/mysql/wt_feature_x__ledger" ]
}

@test "folder deleted with rm: git's record of that worktree is cleared too, and no other's" {
  repo_site ledger
  cd "$PARKED/ledger"
  run vhosty worktree add one
  [ "$status" -eq 0 ]
  run vhosty worktree add two
  [ "$status" -eq 0 ]
  rm -rf "$VHOSTY_DIR/worktrees/ledger/one" "$VHOSTY_DIR/worktrees/ledger/two"
  run vhosty worktree remove one--ledger
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  list="$(git -C "$PARKED/ledger" worktree list)"
  refute_contains "$list" "worktrees/ledger/one"
  assert_contains "$list" "worktrees/ledger/two"
}

@test "adopted folder deleted (by T3): remove still works" {
  repo_site ledger "$MYSQL_ENV"
  services_on
  git -C "$PARKED/ledger" worktree add -q "$HOME/t3/wt" -b x
  run vhosty worktree link "$HOME/t3/wt"
  [ "$status" -eq 0 ]
  git -C "$PARKED/ledger" worktree remove --force "$HOME/t3/wt"
  run vhosty worktree remove x--ledger --yes
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [ ! -e "$HOME/db/mysql/wt_x__ledger" ]
}

@test "folder deleted: the Caddyfile skips the site, and doctor says what's gone and what's left" {
  repo_site ledger "$MYSQL_ENV"
  services_on
  cd "$PARKED/ledger"
  run vhosty worktree add feature/x
  [ "$status" -eq 0 ]
  git -C "$PARKED/ledger" worktree remove --force "$VHOSTY_DIR/worktrees/ledger/feature-x"
  vh write_configs
  assert_contains "$(cat "$VHOSTY_DIR/Caddyfile")" "# Site: feature-x--ledger (skipped"
  run vh eval 'site_load feature-x--ledger; worktree_gone_text feature-x--ledger'
  assert_contains "$output" "is gone"
  assert_contains "$output" "wt_feature_x__ledger"
  assert_contains "$output" "vhosty worktree remove feature-x--ledger"
  # And the check in doctor, with the rest of doctor's world stubbed
  stub dig 'exit 0'
  stub curl 'echo 000'
  stub sudo 'exit 0'
  VHOSTY_UPDATE_CHECK=0 run linux doctor_checks
  [ "$status" -ne 0 ]
  assert_contains "$output" "worktree site feature-x--ledger: folder"
  assert_contains "$output" "vhosty worktree remove feature-x--ledger"
  refute_contains "$output" "site feature-x--ledger: folder $VHOSTY_DIR/worktrees/ledger/feature-x is gone. Remove its config"
}

@test "prune: keeps a site whose database would be orphaned, and says how to drop it" {
  repo_site ledger "$MYSQL_ENV"
  services_on
  cd "$PARKED/ledger"
  run vhosty worktree add feature/x
  [ "$status" -eq 0 ]
  git -C "$PARKED/ledger" worktree remove --force "$VHOSTY_DIR/worktrees/ledger/feature-x"
  run vhosty prune --yes
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  assert_contains "$output" "wt_feature_x__ledger"
  assert_contains "$output" "vhosty worktree remove feature-x--ledger"
  [ "$(conf_value feature-x--ledger SITE_WT_DB_NAME)" = wt_feature_x__ledger ]
  [ -e "$HOME/db/mysql/wt_feature_x__ledger" ]
  # ...and doctor --fix won't offer that prune, or forget it
  [ -z "$(vh stale_sites)" ]
}

@test "prune: removes a gone worktree site with no database left behind" {
  repo_site ledger "$SQLITE_ENV"
  cd "$PARKED/ledger"
  run vhosty worktree add feature/x
  [ "$status" -eq 0 ]
  git -C "$PARKED/ledger" worktree remove --force "$VHOSTY_DIR/worktrees/ledger/feature-x"
  run vhosty prune --yes
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [ ! -e "$VHOSTY_DIR/sites/feature-x--ledger.conf" ]
}

# ---------------------------------------------------------------- php shim

shim_setup() {
  write_config 'VHOSTY_PHP_DEFAULT="9.9"'
  mkdir -p "$VHOSTY_DIR/bin"
  for v in 9.9 9.8 9.7; do
    printf '#!/usr/bin/env bash\necho "php %s $*"\n' "$v" >"$VHOSTY_DIR/bin/php-$v"
    chmod +x "$VHOSTY_DIR/bin/php-$v"
  done
}

in_dir_php() { ( cd "$1" && "$VHOSTY_DIR/bin/php" -v ); }

@test "shim: php in a worktree runs the version it inherited" {
  shim_setup
  repo_site ledger
  site_conf ledger "SITE_PATH=$PARKED/ledger
SITE_PHP=9.8"
  cd "$PARKED/ledger"
  run vhosty worktree add feature/x
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  mkdir -p "$VHOSTY_DIR/worktrees/ledger/feature-x/app/Models"
  [ "$(in_dir_php "$VHOSTY_DIR/worktrees/ledger/feature-x/app/Models")" = "php 9.8 -v" ]
}

@test "shim: a worktree with no pin inside a pinned site runs the default, not that site's" {
  shim_setup
  repo_site ledger
  mkdir -p "$HOME/outer"
  site_conf outer "SITE_PATH=$HOME/outer
SITE_LINKED=yes
SITE_PHP=9.7"
  git -C "$PARKED/ledger" worktree add -q "$HOME/outer/wt" -b x
  run vhosty worktree link "$HOME/outer/wt"
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [ "$(in_dir_php "$HOME/outer/wt")" = "php 9.9 -v" ]
  [ "$(in_dir_php "$HOME/outer")" = "php 9.7 -v" ]
  [ "$(vh site_from_dir "$HOME/outer/wt")" = x--ledger ]
}

@test "shim: a worktree inside its own parent wins over the parent" {
  shim_setup
  repo_site ledger
  site_conf ledger "SITE_PATH=$PARKED/ledger
SITE_PHP=9.8"
  git -C "$PARKED/ledger" worktree add -q "$PARKED/ledger/.wt/x" -b x
  run vhosty worktree link "$PARKED/ledger/.wt/x"
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  vh eval 'site_load x--ledger; SITE_PHP=9.7; site_save x--ledger; write_shim'
  [ "$(in_dir_php "$PARKED/ledger/.wt/x")" = "php 9.7 -v" ]
  [ "$(in_dir_php "$PARKED/ledger")" = "php 9.8 -v" ]
  [ "$(vh site_from_dir "$PARKED/ledger/.wt/x")" = x--ledger ]
}

@test "shim: reached through a symlink, and with spaces in the path" {
  shim_setup
  repo_site ledger
  site_conf ledger "SITE_PATH=$PARKED/ledger
SITE_PHP=9.8"
  git -C "$PARKED/ledger" worktree add -q "$HOME/my trees/one" -b one
  ln -s "$HOME/my trees/one" "$PARKED/ledger/link-to-one"
  run vhosty worktree link "$PARKED/ledger/link-to-one"
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  vh eval 'site_load one--ledger; SITE_PHP=9.7; site_save one--ledger; write_shim'
  [ "$(in_dir_php "$HOME/my trees/one")" = "php 9.7 -v" ]
  # the symlink sits inside the parent: logically there, really the worktree
  [ "$(in_dir_php "$PARKED/ledger/link-to-one")" = "php 9.7 -v" ]
  [ "$(vh site_from_dir "$PARKED/ledger/link-to-one")" = one--ledger ]
  [ "$(in_dir_php "$PARKED/ledger")" = "php 9.8 -v" ]
}

# ---------------------------------------------------------------- listing

@test "list: names, parents, branches, kinds and databases" {
  repo_site ledger "$MYSQL_ENV"
  services_on
  cd "$PARKED/ledger"
  run vhosty worktree
  [ "$status" -eq 0 ]
  assert_contains "$output" "No worktree sites"
  run vhosty worktree add feature/x
  [ "$status" -eq 0 ]
  git -C "$PARKED/ledger" worktree add -q "$HOME/t3/wt" -b y
  run vhosty worktree link "$HOME/t3/wt"
  [ "$status" -eq 0 ]
  run vhosty worktree list
  [ "$status" -eq 0 ]
  assert_contains "$output" "https://feature-x--ledger.test.example"
  assert_contains "$output" "feature/x, worktree of ledger, created"
  assert_contains "$output" "https://y--ledger.test.example"
  assert_contains "$output" "y, worktree of ledger, adopted"
  assert_contains "$output" "mysql database wt_y__ledger on the mysql service"
}

@test "sites and site show the parent; url and open work" {
  repo_site ledger "$MYSQL_ENV"
  services_on
  cd "$PARKED/ledger"
  run vhosty worktree add feature/x
  [ "$status" -eq 0 ]
  run vhosty sites
  [ "$status" -eq 0 ]
  assert_contains "$output" "https://feature-x--ledger.test.example"
  assert_contains "$output" "worktree of ledger"
  run vhosty site feature-x--ledger
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  assert_contains "$output" "worktree of ledger, feature/x (created)"
  assert_contains "$output" "wt_feature_x__ledger"
  run vhosty site ledger
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  assert_contains "$output" "feature-x--ledger"
  cd "$VHOSTY_DIR/worktrees/ledger/feature-x"
  run vh site_url
  [ "$output" = "https://feature-x--ledger.test.example" ]
  run vh site_url feature-x--ledger
  [ "$output" = "https://feature-x--ledger.test.example" ]
  stub open 'exit 0'   # macOS; on Linux with no display it prints the URL
  DISPLAY="" WAYLAND_DISPLAY="" run vhosty open
  [ "$status" -eq 0 ]
  assert_contains "$output" "https://feature-x--ledger.test.example"
}

# ---------------------------------------------------------------- parents going away

@test "unlink: a worktree site is refused, as it's more than a link" {
  repo_site ledger "$MYSQL_ENV"
  services_on
  cd "$PARKED/ledger"
  run vhosty worktree add feature/x
  [ "$status" -eq 0 ]
  run vhosty unlink feature-x--ledger
  [ "$status" -ne 0 ]
  assert_contains "$output" "vhosty worktree remove feature-x--ledger"
  [ -f "$VHOSTY_DIR/sites/feature-x--ledger.conf" ]
}

@test "unlink of a parent says its worktree sites stay, and they do" {
  mkdir -p "$HOME/Projects"
  repo_site ledger
  mv "$PARKED/ledger" "$HOME/Projects/ledger"
  vh cmd_link "$HOME/Projects/ledger" --name ledger >/dev/null
  cd "$HOME/Projects/ledger"
  run vhosty worktree add feature/x
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  run vhosty unlink ledger
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  assert_contains "$output" "worktree sites stay: feature-x--ledger"
  [ -f "$VHOSTY_DIR/sites/feature-x--ledger.conf" ]
  assert_contains "$(cat "$VHOSTY_DIR/Caddyfile")" "@site_feature-x--ledger"
  run vhosty worktree list
  assert_contains "$output" "ledger, no longer a site"
  # ...and it can still be removed
  run vhosty worktree remove feature-x--ledger
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
}

@test "unpark of a parent's folder says its worktree sites stay, and they do" {
  repo_site ledger
  cd "$PARKED/ledger"
  run vhosty worktree add feature/x
  [ "$status" -eq 0 ]
  cd "$HOME"
  run vhosty unpark "$PARKED"
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  assert_contains "$output" "worktree sites stay: feature-x--ledger"
  assert_contains "$(cat "$VHOSTY_DIR/Caddyfile")" "@site_feature-x--ledger"
}

@test "prune of a parent says its worktree sites stay" {
  mkdir -p "$HOME/Projects"
  repo_site ledger
  mv "$PARKED/ledger" "$HOME/Projects/ledger"
  vh cmd_link "$HOME/Projects/ledger" --name ledger >/dev/null
  cd "$HOME/Projects/ledger"
  run vhosty worktree add feature/x
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  cd "$HOME"
  rm -rf "$HOME/Projects/ledger"
  run vhosty prune --yes
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  assert_contains "$output" "worktree sites stay: feature-x--ledger"
  [ -f "$VHOSTY_DIR/sites/feature-x--ledger.conf" ]
}

@test "remove: with the repository gone, git can't remove it, and vhosty won't delete it by hand" {
  mkdir -p "$HOME/Projects"
  repo_site ledger
  mv "$PARKED/ledger" "$HOME/Projects/ledger"
  vh cmd_link "$HOME/Projects/ledger" --name ledger >/dev/null
  cd "$HOME/Projects/ledger"
  run vhosty worktree add feature/x
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  cd "$HOME"
  rm -rf "$HOME/Projects/ledger"
  wt="$VHOSTY_DIR/worktrees/ledger/feature-x"
  run vhosty worktree remove feature-x--ledger --yes
  [ "$status" -ne 0 ]
  assert_contains "$output" "won't delete it by hand"
  [ -d "$wt/public" ]
  [ -f "$VHOSTY_DIR/sites/feature-x--ledger.conf" ]
  # Once the folder is out of the way, it goes
  rm -rf "$wt"
  run vhosty worktree remove feature-x--ledger --yes
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [ ! -e "$VHOSTY_DIR/sites/feature-x--ledger.conf" ]
}

# ---------------------------------------------------------------- Herd

@test "Herd: the command is refused, pointing at Herd" {
  write_config 'VHOSTY_BACKEND="herd"'
  run vhosty worktree add x
  [ "$status" -ne 0 ]
  assert_contains "$output" "Herd serves the sites"
  assert_contains "$output" "herd link"
}

# ---------------------------------------------------------------- Caddy

@test "Caddyfile: a -- name gets its own route, before the parked {labels.N} rules" {
  repo_site ledger
  cd "$PARKED/ledger"
  run vhosty worktree add feature/x
  [ "$status" -eq 0 ]
  caddyfile="$(cat "$VHOSTY_DIR/Caddyfile")"
  assert_contains "$caddyfile" "@site_feature-x--ledger host feature-x--ledger.test.example"
  site_line="$(grep -n '@site_feature-x--ledger host' "$VHOSTY_DIR/Caddyfile" | cut -d: -f1)"
  parked_line="$(grep -n '# Parked:' "$VHOSTY_DIR/Caddyfile" | head -1 | cut -d: -f1)"
  [ "$site_line" -lt "$parked_line" ]
}

@test "Caddyfile with -- names is valid to a real Caddy, and routes them" {
  [ -x "$CADDY" ] || skip "no Caddy with the Cloudflare plugin (set VHOSTY_TEST_CADDY)"
  repo_site ledger
  site_conf ledger "SITE_PATH=$PARKED/ledger
SITE_INI='memory_limit=2G'"
  cd "$PARKED/ledger"
  run vhosty worktree add feature/x
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  # A static one too: its dotfile matcher gets the name as well
  mkdir -p "$HOME/static" && echo '<h1>the worktree</h1>' >"$HOME/static/index.html" && echo 'SECRET=1' >"$HOME/static/.env"
  site_conf static--ledger "SITE_PATH=$HOME/static
SITE_LINKED=yes
SITE_WT_KIND=adopted
SITE_WT_PARENT=ledger"
  long="$(vh worktree_name "$(printf 'long-branch-%.0s' 1 2 3 4 5 6 7)" ledger)"
  mkdir -p "$HOME/long"; echo '<h1>long</h1>' >"$HOME/long/index.html"
  site_conf "$long" "SITE_PATH=$HOME/long
SITE_LINKED=yes
SITE_WT_KIND=adopted
SITE_WT_PARENT=ledger"
  vh write_configs
  CF_API_TOKEN=0123456789abcdef0123456789abcdef01234567 run "$CADDY" validate --config "$VHOSTY_DIR/Caddyfile" --adapter caddyfile
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  sed -e '/^\tadmin /d' -e "s/^\tdefault_bind .*/\tadmin off\n\tauto_https off\n\tdefault_bind 127.0.0.1/" \
      -e "s/^\*\.test\.example {/http:\/\/*.test.example:$PORT {/" \
      -e '/^\ttls {/,/^\t}/d' "$VHOSTY_DIR/Caddyfile" >"$HOME/test.Caddyfile"
  "$CADDY" run --config "$HOME/test.Caddyfile" --adapter caddyfile >"$HOME/caddy.log" 2>&1 &
  CADDY_PID=$!
  for _ in $(seq 1 50); do
    curl -s -o /dev/null "http://127.0.0.1:$PORT/" -H "Host: x.test.example" && break
    sleep 0.1
  done
  run curl -s -H "Host: static--ledger.test.example" "http://127.0.0.1:$PORT/"
  assert_contains "$output" "the worktree"
  run curl -s -H "Host: $long.test.example" "http://127.0.0.1:$PORT/"
  assert_contains "$output" "long"
  run curl -s -o /dev/null -w '%{http_code}' -H "Host: static--ledger.test.example" "http://127.0.0.1:$PORT/.env"
  [ "$output" = 404 ]
  # A -- name with no site falls through to "no site", not to something else's folder
  run curl -s -o /dev/null -w '%{http_code}' -H "Host: nosuch--ledger.test.example" "http://127.0.0.1:$PORT/"
  [ "$output" = 404 ]
}

# ---------------------------------------------------------------- usage

@test "usage: unknown subcommands and options say how" {
  repo_site ledger
  cd "$PARKED/ledger"
  run vhosty worktree frobnicate
  [ "$status" -ne 0 ]
  assert_contains "$output" "Usage: vhosty worktree"
  run vhosty worktree add
  [ "$status" -ne 0 ]
  assert_contains "$output" "Usage: vhosty worktree add"
  run vhosty worktree remove
  [ "$status" -ne 0 ]
  assert_contains "$output" "Usage: vhosty worktree remove"
  run vhosty help
  assert_contains "$output" "vhosty worktree add <branch>"
}
