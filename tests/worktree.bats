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

vhosty() { "${VHOSTY_TEST_BASH:-bash}" "$ROOT/bin/vhosty" "$@"; }

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
{"Service":"mysql","Image":"mysql:8.4","State":"running","Health":"healthy","Publishers":[{"URL":"127.0.0.1","TargetPort":3306,"PublishedPort":3306}]}
{"Service":"postgres","Image":"pgvector/pgvector:pg18-trixie","State":"running","Health":"healthy","Publishers":[{"URL":"127.0.0.1","TargetPort":5432,"PublishedPort":5432}]}
JSON
  stub docker 'printf "%s\n" "docker $*" >>"$HOME/docker.log"
/bin/pwd >/dev/null 2>&1 || { echo "getwd: no such file or directory" >&2; exit 1; }
case "$1" in info|image) exit 0 ;; compose) ;; *) exit 1 ;; esac
shift 3   # compose --project-directory DIR
case "$1" in
  config) [ ! -f "$HOME/compose-fails" ] && cat "$HOME/compose.json" ;;
  ps) [ ! -f "$HOME/ps-fails" ] && cat "$HOME/ps.json" ;;
  up) exit 0 ;;
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
  *information_schema.TRIGGERS*) [ ! -f "$HOME/not-copied-fails" ] || exit 1; [ ! -f "$HOME/not-copied" ] || cat "$HOME/not-copied" ;;
  *information_schema.schemata*) n="$(printf "%s" "$sql" | sed -n "s/.*schema_name = .\(.*\).$/\1/p")"
    if [ -e "$HOME/db/mysql/$n" ]; then echo 1; else echo 0; fi ;;
  "show databases") ls "$HOME/db/mysql" ;;
  "select 1") echo 1 ;;
  "CREATE DATABASE"*) [ ! -e "$HOME/db/mysql/$n" ] || exit 1; [ ! -f "$HOME/create-fails" ] || exit 1; : >"$HOME/db/mysql/$n" ;;
  "DROP DATABASE"*) [ ! -f "$HOME/drop-fails" ] || exit 1; [ -e "$HOME/db/mysql/$n" ] || exit 1; rm -f "$HOME/db/mysql/$n" ;;
  select\ concat*) echo "GRANT ALL PRIVILEGES ON \`$n\`.* TO $(printf "%s" "$sql" | sed -n "s/.*User = \(.*\)$/\1/p")@'"'"'%'"'"';" ;;
  *) exit 1 ;;
esac'
  stub mysqldump 'case " $* " in *" --help "*) [ -f "$HOME/no-gtid-option" ] || echo "  --set-gtid-purged=name"; exit 0 ;; esac
printf "%s\n" "mysqldump $*" >>"$HOME/dump.log"; [ ! -f "$HOME/dump-fails" ] || exit 1
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
  "select 1") echo 1 ;;
  *"from pg_database where not datistemplate"*) ls "$HOME/db/postgres" ;;
  *"from pg_database"*) n="$(printf "%s" "$sql" | sed -n "s/.*datname = .\(.*\).$/\1/p")"
    if [ -e "$HOME/db/postgres/$n" ]; then echo 1; else echo 0; fi ;;
  *"from pg_roles"*) echo 1 ;;
  *"from pg_class"*) echo 0 ;;
  *"pg_foreign_table"*) [ ! -f "$HOME/reach-fails" ] || exit 1; [ ! -f "$HOME/reach" ] || cat "$HOME/reach" ;;
  *"from pg_extension"*) [ ! -f "$HOME/ext-fails" ] || exit 1; if [ -f "$HOME/extensions" ]; then cat "$HOME/extensions"; else echo "vector|public"; fi ;;
  "CREATE EXTENSION"*|"CREATE SCHEMA"*) ;;
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
  refute vh worktree_db_name_ok wt_
  refute vh worktree_db_name_ok WT_upper
  refute vh worktree_db_name_ok "wt_$(printf 'a%.0s' $(seq 1 61))"
  refute vh worktree_db_name_ok 'wt_ok
DROP DATABASE ledger'
  refute vh worktree_ident_ok 'ledger
DROP DATABASE ledger'
  refute vh worktree_ident_ok '-rf'
  refute vh worktree_ident_ok ''
  refute vh worktree_ident_ok 'a b'
  vh worktree_ident_ok agents_own.v2-x
  refute vh worktree_db_name_ok ledger
  refute vh worktree_db_name_ok 'wt_x`; DROP DATABASE ledger'
  refute vh worktree_db_name_ok 'wt_"x'
  refute vh worktree_db_name_ok ''
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
  run vh worktree_env_set "$HOME/e" A changed
  [ "$status" -ne 0 ]
  assert_contains "$output" "is a link"
  [ "$(cat "$HOME/target")" = "A=target" ]
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
  refute git -C "$PARKED/ledger" show-ref --verify --quiet refs/heads/feature/x
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
  refute git -C "$PARKED/ledger" show-ref --verify --quiet refs/heads/one
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
  run vhosty worktree add y --share-db
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
  assert_contains "$dump" "--set-gtid-purged=OFF"
  [ "$(conf_value feature-x--ledger SITE_WT_DB_KIND)" = mysql ]
  [ "$(conf_value feature-x--ledger SITE_WT_DB_SERVICE)" = mysql ]
  [ "$(conf_value feature-x--ledger SITE_WT_DB_NAME)" = wt_feature_x__ledger ]
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
  assert_contains "$(cat "$HOME/sql.log")" "load into (none): GRANT ALL PRIVILEGES ON \`wt_feature_x__ledger\`.* TO 'ledger_app'@'%';"
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
  refute git -C "$PARKED/ledger" show-ref --verify --quiet refs/heads/feature/x
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
  assert_contains "$output" "Start it"
  assert_contains "$output" "vhosty services up mysql"
  [ ! -e "$VHOSTY_DIR/worktrees" ]
}

@test "mysql: compose that can't be read stops it, rather than sharing the database" {
  repo_site ledger "$MYSQL_ENV"
  services_on
  touch "$HOME/ps-fails"
  cd "$PARKED/ledger"
  run vhosty worktree add feature/x
  [ "$status" -ne 0 ]
  assert_contains "$output" "Can't read the docker services"
  [ ! -e "$VHOSTY_DIR/worktrees" ]
  # Nothing running there, and a file it can't read either
  rm "$HOME/ps-fails"
  : >"$HOME/ps.json"
  touch "$HOME/compose-fails"
  run vhosty worktree add feature/x
  [ "$status" -ne 0 ]
  assert_contains "$output" "Can't read the docker services"
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

# A PATH with everything on it but sqlite3, as most machines have one, and CI does
hide_sqlite3() {
  command -v sqlite3 >/dev/null 2>&1 || return 0
  local d="$HOME/nosqlite3" dir f n
  mkdir -p "$d"
  local IFS=:
  for dir in $PATH; do
    for f in "$dir"/*; do
      n="${f##*/}"
      if [ "$n" != sqlite3 ] && [ -x "$f" ] && [ ! -e "$d/$n" ]; then ln -s "$f" "$d/$n"; fi
    done
  done
  export PATH="$d"
}

@test "sqlite: --copy-db with no sqlite3 copies the file, a path in .env included, and says so" {
  hide_sqlite3
  refute command -v sqlite3
  repo_site ledger 'DB_CONNECTION=sqlite
DB_DATABASE=database/custom.sqlite'
  echo data >"$PARKED/ledger/database/custom.sqlite"
  cd "$PARKED/ledger"
  run vhosty worktree add feature/x --copy-db
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  assert_contains "$output" "plain file copy"
  [ "$(cat "$VHOSTY_DIR/worktrees/ledger/feature-x/database/database.sqlite")" = data ]
  [ "$(cat "$PARKED/ledger/database/custom.sqlite")" = data ]
  [ "$(conf_value feature-x--ledger SITE_WT_DB_KIND)" = sqlite ]
}

@test "sqlite: --copy-db with a real sqlite3 makes a real copy" {
  command -v sqlite3 >/dev/null 2>&1 || skip "no sqlite3 here"
  repo_site ledger "$SQLITE_ENV"
  sqlite3 "$PARKED/ledger/database/database.sqlite" 'create table t (a); insert into t values (42);'
  cd "$PARKED/ledger"
  run vhosty worktree add feature/x --copy-db
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [ "$(sqlite3 "$VHOSTY_DIR/worktrees/ledger/feature-x/database/database.sqlite" 'select a from t')" = 42 ]
}

@test "sqlite: a backup that fails is reported, and the worktree starts empty" {
  repo_site ledger "$SQLITE_ENV"
  echo not-a-database >"$PARKED/ledger/database/database.sqlite"
  stub sqlite3 'echo "Error: file is not a database" >&2; exit 1'
  cd "$PARKED/ledger"
  run vhosty worktree add feature/x --copy-db
  [ "$status" -ne 0 ]
  assert_contains "$output" "couldn't copy ledger's sqlite file"
  [ ! -s "$VHOSTY_DIR/worktrees/ledger/feature-x/database/database.sqlite" ]
  [ "$(cat "$PARKED/ledger/database/database.sqlite")" = not-a-database ]
}

@test "sqlite: --copy-db uses sqlite3's backup, read only, when there's a sqlite3" {
  repo_site ledger 'DB_CONNECTION=sqlite
DB_DATABASE=database/custom.sqlite'
  echo data >"$PARKED/ledger/database/custom.sqlite"
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

# Stops before git does anything, or composer's reached, naming where it is
shared_case() { # shared_case ENV_TEXT WHERE
  repo_site ledger "$1"
  services_on
  cd "$PARKED/ledger"
  run vhosty worktree add feature/x
  [ "$status" -ne 0 ]
  assert_contains "$output" "would share ledger's database ($2)"
  assert_contains "$output" "--share-db"
  assert_contains "$output" "Nothing changed"
  refute_contains "$output" "hunter2secret"
  refute git -C "$PARKED/ledger" show-ref --verify --quiet refs/heads/feature/x
  [ ! -e "$VHOSTY_DIR/worktrees" ]
  [ ! -e "$VHOSTY_DIR/sites/feature-x--ledger.conf" ]
  [ ! -e "$HOME/composer.log" ]
  [ ! -e "$HOME/sql.log" ]
  # --copy-db can't copy it, whatever else is passed
  run vhosty worktree add feature/x --copy-db
  [ "$status" -ne 0 ]
  assert_contains "$output" "--copy-db can't copy that database"
  refute_contains "$output" "hunter2secret"
  [ ! -e "$HOME/dump.log" ]
  refute git -C "$PARKED/ledger" show-ref --verify --quiet refs/heads/feature/x
  # Asked for, it's shared and on record, and composer may run
  git -C "$PARKED/ledger" branch -q placeholder
  printf '{}\n' >"$PARKED/ledger/composer.json"
  git -C "$PARKED/ledger" add composer.json
  git -C "$PARKED/ledger" commit -qm composer
  run vhosty worktree add feature/x --share-db
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  assert_contains "$output" "SHARES ledger's database"
  refute_contains "$output" "hunter2secret"
  [ "$(vh worktree_env_get "$VHOSTY_DIR/worktrees/ledger/feature-x/.env" DB_DATABASE)" = "$(vh worktree_env_get "$PARKED/ledger/.env" DB_DATABASE)" ]
  [ "$(conf_value feature-x--ledger SITE_WT_DB_SHARED)" = "$2" ]
  [ -z "$(conf_value feature-x--ledger SITE_WT_DB_KIND)" ]
  refute_contains "$(conf feature-x--ledger)" "hunter2secret"
  assert_contains "$(cat "$HOME/composer.log")" "composer install"
  [ ! -e "$HOME/sql.log" ]
}

@test "a remote database host stops it, unless --share-db" {
  shared_case "${MYSQL_ENV/DB_HOST=127.0.0.1/DB_HOST=db.example.com}" "db.example.com:3306, database ledger"
  refute_contains "$output" "php artisan migrate --seed"
  run vhosty worktree list
  assert_contains "$output" "db.example.com:3306, database ledger"
  run vhosty site feature-x--ledger
  assert_contains "$output" "db.example.com:3306, database ledger"
  run vhosty doctor
  assert_contains "$output" "feature-x--ledger shares ledger's database (--share-db): db.example.com:3306, database ledger"
  # Removing it can't drop what it never made
  run vhosty worktree remove feature-x--ledger --yes
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [ ! -e "$HOME/sql.log" ]
}

@test "a local port no vhosty service publishes stops it, unless --share-db" {
  shared_case "${MYSQL_ENV/DB_PORT=3306/DB_PORT=3307}" "127.0.0.1:3307, database ledger"
}

@test "a port published by a service of another kind stops it, unless --share-db" {
  shared_case "${MYSQL_ENV/DB_PORT=3306/DB_PORT=6379}" "127.0.0.1:6379, database ledger"
}

@test "a socket connection stops it, unless --share-db" {
  shared_case "$MYSQL_ENV
DB_SOCKET=/var/run/mysqld/mysqld.sock" "127.0.0.1:3306, database ledger"
}

@test "a database URL stops it, unless --share-db, and its password is never printed" {
  shared_case "$MYSQL_ENV
DB_URL=mysql://u:hunter2secret@db.example.com:3306/ledger?ssl=1" "db.example.com:3306, database ledger"
}

@test "a connection vhosty doesn't manage stops it, unless --share-db" {
  shared_case 'DB_CONNECTION=sqlsrv
DB_HOST=db.example.com
DB_DATABASE=ledger
DB_PASSWORD=hunter2secret' "db.example.com, database ledger"
}

@test "database settings with no DB_CONNECTION stop it too: vhosty can't tell" {
  shared_case 'DB_HOST=db.example.com
DB_DATABASE=ledger
DB_PASSWORD=hunter2secret' "db.example.com, database ledger"
}

@test "no database settings at all: nothing to share, nothing stops" {
  repo_site ledger 'APP_KEY=x'
  services_on
  cd "$PARKED/ledger"
  run vhosty worktree add feature/x
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  refute_contains "$output" "share"
}

@test "with no docker services set up, a local database stops it, unless --share-db" {
  repo_site ledger "$MYSQL_ENV"
  cd "$PARKED/ledger"
  run vhosty worktree add feature/x
  [ "$status" -ne 0 ]
  assert_contains "$output" "no vhosty docker services"
  refute git -C "$PARKED/ledger" show-ref --verify --quiet refs/heads/feature/x
  [ ! -e "$HOME/docker.log" ]
  run vhosty worktree add feature/x --share-db
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  assert_contains "$output" "SHARES ledger's database"
  [ ! -e "$HOME/docker.log" ]
}

@test "--share-db on vhosty's own services shares it: no new database" {
  repo_site ledger "$MYSQL_ENV"
  services_on
  mysql_db ledger
  cd "$PARKED/ledger"
  run vhosty worktree add feature/x --share-db
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [ "$(vh worktree_env_get "$VHOSTY_DIR/worktrees/ledger/feature-x/.env" DB_DATABASE)" = ledger ]
  [ ! -e "$HOME/db/mysql/wt_feature_x__ledger" ]
  [ "$(conf_value feature-x--ledger SITE_WT_DB_SHARED)" = "127.0.0.1:3306, database ledger" ]
  run vhosty worktree remove feature-x--ledger --yes
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [ "$(cat "$HOME/db/mysql/ledger")" = "row of ledger" ]
}

@test "--copy-db and --share-db together are refused before anything" {
  repo_site ledger "$MYSQL_ENV"
  services_on
  cd "$PARKED/ledger"
  run vhosty worktree add feature/x --copy-db --share-db
  [ "$status" -ne 0 ]
  assert_contains "$output" "Pick one"
  git -C "$PARKED/ledger" worktree add -q "$HOME/wt" -b y
  run vhosty worktree link "$HOME/wt" --share-db --copy-db
  [ "$status" -ne 0 ]
  assert_contains "$output" "Pick one"
  [ ! -e "$HOME/docker.log" ]
}

@test "link: a remote database stops it too, and leaves its folder alone" {
  repo_site ledger "${MYSQL_ENV/DB_HOST=127.0.0.1/DB_HOST=db.example.com}"
  services_on
  git -C "$PARKED/ledger" worktree add -q "$HOME/wt" -b x
  run vhosty worktree link "$HOME/wt"
  [ "$status" -ne 0 ]
  assert_contains "$output" "db.example.com:3306, database ledger"
  [ ! -e "$HOME/wt/.env" ]
  [ ! -e "$VHOSTY_DIR/sites/x--ledger.conf" ]
  run vhosty worktree link "$HOME/wt" --share-db
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [ -n "$(conf_value x--ledger SITE_WT_DB_SHARED)" ]
}

# A worktree whose sqlite resolves to the parent's: a link, or a path in its .env
sqlite_shared_case() {
  [ -z "$(vh worktree_env_get "$HOME/wt/.env" APP_URL)" ]
  [ ! -e "$VHOSTY_DIR/sites/x--ledger.conf" ]
  before="$(cat "$HOME/wt/.env" 2>/dev/null || true)"
  run vhosty worktree link "$HOME/wt"
  [ "$status" -ne 0 ]
  assert_contains "$output" "would share ledger's database"
  assert_contains "$output" "Nothing changed"
  [ "$(cat "$HOME/wt/.env" 2>/dev/null || true)" = "$before" ]
  [ ! -e "$VHOSTY_DIR/sites/x--ledger.conf" ]
  [ ! -e "$HOME/composer.log" ]
  run vhosty worktree link "$HOME/wt" --copy-db
  [ "$status" -ne 0 ]
  assert_contains "$output" "--copy-db can't copy"
  run vhosty worktree link "$HOME/wt" --share-db
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [ "$(cat "$PARKED/ledger/database/database.sqlite")" = parents-data ]
  [ "$(vh worktree_real_file "$(vh worktree_env_get "$HOME/wt/.env" DB_DATABASE)")" = "$PARKED/ledger/database/database.sqlite" ]
  assert_contains "$(conf_value x--ledger SITE_WT_DB_SHARED)" "$PARKED/ledger/database/database.sqlite"
  [ -z "$(conf_value x--ledger SITE_WT_DB_KIND)" ]
  run vhosty worktree remove x--ledger --yes
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [ "$(cat "$PARKED/ledger/database/database.sqlite")" = parents-data ]
}

@test "link: sqlite through a symlinked database/ is the parent's: refused without --share-db" {
  repo_site ledger "$SQLITE_ENV"
  echo parents-data >"$PARKED/ledger/database/database.sqlite"
  git -C "$PARKED/ledger" worktree add -q "$HOME/wt" -b x
  mv "$HOME/wt/database" "$HOME/wt/database.orig"
  ln -s "$PARKED/ledger/database" "$HOME/wt/database"
  sqlite_shared_case
}

@test "link: sqlite through a symlinked file is the parent's: refused without --share-db" {
  repo_site ledger "$SQLITE_ENV"
  echo parents-data >"$PARKED/ledger/database/database.sqlite"
  git -C "$PARKED/ledger" worktree add -q "$HOME/wt" -b x
  ln -s "$PARKED/ledger/database/database.sqlite" "$HOME/wt/database/database.sqlite"
  sqlite_shared_case
}

@test "link: sqlite whose .env names the parent's file: refused without --share-db" {
  repo_site ledger "$SQLITE_ENV"
  echo parents-data >"$PARKED/ledger/database/database.sqlite"
  git -C "$PARKED/ledger" worktree add -q "$HOME/wt" -b x
  printf 'DB_CONNECTION=sqlite\nDB_DATABASE=%s\n' "$PARKED/ledger/database/database.sqlite" >"$HOME/wt/.env"
  sqlite_shared_case
}

@test "link: sqlite hard linked to the parent's file is the parent's too" {
  repo_site ledger "$SQLITE_ENV"
  echo parents-data >"$PARKED/ledger/database/database.sqlite"
  git -C "$PARKED/ledger" worktree add -q "$HOME/wt" -b x
  ln "$PARKED/ledger/database/database.sqlite" "$HOME/wt/database/database.sqlite"
  run vhosty worktree link "$HOME/wt"
  [ "$status" -ne 0 ]
  assert_contains "$output" "would share ledger's database"
  [ ! -e "$VHOSTY_DIR/sites/x--ledger.conf" ]
}

@test "link: a database/ that links anywhere else out of the worktree is refused too" {
  repo_site ledger "$SQLITE_ENV"
  mkdir -p "$HOME/elsewhere"
  git -C "$PARKED/ledger" worktree add -q "$HOME/wt" -b x
  mv "$HOME/wt/database" "$HOME/wt/database.orig"
  ln -s "$HOME/elsewhere" "$HOME/wt/database"
  run vhosty worktree link "$HOME/wt"
  [ "$status" -ne 0 ]
  assert_contains "$output" "link out of the worktree"
  [ -z "$(ls "$HOME/elsewhere")" ]
  rm "$HOME/wt/database"
  ln -s "$HOME/nowhere" "$HOME/wt/database"
  run vhosty worktree link "$HOME/wt"
  [ "$status" -ne 0 ]
  assert_contains "$output" "broken link"
}

@test "add: a branch that tracks a database/ link gets no database there, and no composer" {
  repo_site ledger "$SQLITE_ENV"
  mkdir -p "$HOME/elsewhere"
  printf '{}\n' >"$PARKED/ledger/composer.json"
  git -C "$PARKED/ledger" add composer.json
  git -C "$PARKED/ledger" commit -qm composer
  git -C "$PARKED/ledger" checkout -qb linked
  git -C "$PARKED/ledger" rm -qr database
  ln -s "$HOME/elsewhere" "$PARKED/ledger/database"
  git -C "$PARKED/ledger" add database
  git -C "$PARKED/ledger" commit -qm link
  git -C "$PARKED/ledger" checkout -q main
  cd "$PARKED/ledger"
  run vhosty worktree add linked
  [ "$status" -ne 0 ]
  assert_contains "$output" "link out of the worktree"
  [ -z "$(ls "$HOME/elsewhere")" ]
  [ ! -e "$HOME/composer.log" ]
  [ ! -e "$VHOSTY_DIR/sites/linked--ledger.conf" ]
  [ ! -e "$VHOSTY_DIR/worktrees/ledger/linked" ]
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
  refute_contains "$(cat "$HOME/sql.log")" "CREATE DATABASE"
  assert_contains "$output" "isn't there"
  mysql_db agents_own
  run vhosty worktree link "$HOME/wt"
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  refute_contains "$output" "isn't there"
}

@test "link: a cached config stops it, as Laravel reads that and not .env" {
  repo_site ledger
  git -C "$PARKED/ledger" worktree add -q "$HOME/wt" -b x
  mkdir -p "$HOME/wt/bootstrap/cache"
  echo '<?php' >"$HOME/wt/bootstrap/cache/config.php"
  run vhosty worktree link "$HOME/wt"
  [ "$status" -eq 1 ]
  assert_contains "$output" "config:clear"
  assert_contains "$output" "Nothing changed"
  [ ! -f "$VHOSTY_DIR/sites/x--ledger.conf" ]
  rm "$HOME/wt/bootstrap/cache/config.php"
  run vhosty worktree link "$HOME/wt"
  [ "$status" -eq 0 ]
}

@test "link --share-db: a cached config only warns, as sharing was asked for" {
  repo_site ledger
  git -C "$PARKED/ledger" worktree add -q "$HOME/wt" -b x
  mkdir -p "$HOME/wt/bootstrap/cache"
  echo '<?php' >"$HOME/wt/bootstrap/cache/config.php"
  run vhosty worktree link "$HOME/wt" --share-db
  [ "$status" -eq 0 ]
  assert_contains "$output" "config:clear"
}

# ---------------------------------------------------------------- env warnings

@test "warns about settings that still name the parent's address, without their values" {
  repo_site ledger 'APP_URL=https://ledger.test.example
MY_CALLBACK=https://ledger.test.example/hook
OTHER=not-ledger.test.example
SECRET=abc
DB_CONNECTION=sqlite'
  cd "$PARKED/ledger"
  run vhosty worktree add feature/x
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  assert_contains "$output" "still name ledger's address: MY_CALLBACK"
  refute_contains "$output" "MY_CALLBACK OTHER"
  refute_contains "$output" "APP_URL MY"
  refute_contains "$output" "/hook"
}

@test ".env: REDIS_PREFIX and CACHE_PREFIX are the worktree's own, and say so" {
  repo_site ledger 'APP_NAME=Ledger
DB_CONNECTION=sqlite
CACHE_STORE=redis'
  before="$(cksum <"$PARKED/ledger/.env")"
  cd "$PARKED/ledger"
  run vhosty worktree add feature/x
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  e="$VHOSTY_DIR/worktrees/ledger/feature-x/.env"
  [ "$(vh worktree_env_get "$e" REDIS_PREFIX)" = "feature-x--ledger-database-" ]
  [ "$(vh worktree_env_get "$e" CACHE_PREFIX)" = "feature-x--ledger-cache-" ]
  assert_contains "$output" "REDIS_PREFIX and CACHE_PREFIX are its own"
  assert_contains "$output" "queue jobs"
  # What a prefix can't do, on a real Redis too: cache:clear is a FLUSHDB
  assert_contains "$output" "cache:clear here empties all of that Redis cache database, ledger's cache too"
  [ "$(cksum <"$PARKED/ledger/.env")" = "$before" ]
}

@test ".env: prefixes already there are replaced, not duplicated, and the parent's stays byte for byte" {
  repo_site ledger 'DB_CONNECTION=sqlite
REDIS_PREFIX=ledger_
CACHE_PREFIX="ledger_cache_"
# REDIS_PREFIX=a-comment
REDIS_PREFIX=ledger_again_'
  before="$(cksum <"$PARKED/ledger/.env")"
  cd "$PARKED/ledger"
  run vhosty worktree add feature/x
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  e="$VHOSTY_DIR/worktrees/ledger/feature-x/.env"
  [ "$(grep -c '^REDIS_PREFIX=feature-x--ledger-database-$' "$e")" = 2 ]
  [ "$(grep -c '^REDIS_PREFIX=' "$e")" = 2 ]
  [ "$(grep -c '^CACHE_PREFIX=' "$e")" = 1 ]
  [ "$(vh worktree_env_get "$e" CACHE_PREFIX)" = "feature-x--ledger-cache-" ]
  [ "$(cksum <"$PARKED/ledger/.env")" = "$before" ]
}

@test ".env: with the cache elsewhere, cache:clear isn't worth a warning" {
  repo_site ledger 'DB_CONNECTION=sqlite
CACHE_STORE=database'
  cd "$PARKED/ledger"
  run vhosty worktree add feature/x
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  refute_contains "$output" "cache:clear"
}

@test ".env: an adopted worktree's own prefix stays, the parent's doesn't" {
  repo_site ledger 'DB_CONNECTION=sqlite
REDIS_PREFIX=ledger_
CACHE_PREFIX=ledger_cache_'
  git -C "$PARKED/ledger" worktree add -q "$HOME/wt" -b x
  printf 'DB_CONNECTION=sqlite\nREDIS_PREFIX=mine_\nCACHE_PREFIX=ledger_cache_\n' >"$HOME/wt/.env"
  run vhosty worktree link "$HOME/wt"
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [ "$(vh worktree_env_get "$HOME/wt/.env" REDIS_PREFIX)" = mine_ ]
  [ "$(vh worktree_env_get "$HOME/wt/.env" CACHE_PREFIX)" = "x--ledger-cache-" ]
}

@test ".env: the parent's SESSION_DOMAIN is cleared, with Laravel's null, and said" {
  repo_site ledger 'DB_CONNECTION=sqlite
SESSION_DOMAIN=.ledger.test.example'
  before="$(cksum <"$PARKED/ledger/.env")"
  cd "$PARKED/ledger"
  run vhosty worktree add feature/x
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  e="$VHOSTY_DIR/worktrees/ledger/feature-x/.env"
  [ "$(vh worktree_env_get "$e" SESSION_DOMAIN)" = null ]
  assert_contains "$output" "SESSION_DOMAIN cleared"
  refute_contains "$output" "still name ledger's address"
  [ "$(cksum <"$PARKED/ledger/.env")" = "$before" ]
}

@test ".env: no SESSION_DOMAIN, or null already, isn't mentioned" {
  repo_site ledger 'DB_CONNECTION=sqlite
SESSION_DOMAIN=null'
  cd "$PARKED/ledger"
  run vhosty worktree add feature/x
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  refute_contains "$output" "SESSION_DOMAIN"
}

@test ".env: warns once about what's still shared, by key name, never by value" {
  repo_site ledger 'APP_ENV=production
DB_CONNECTION=sqlite
FILESYSTEM_DISK=s3
AWS_BUCKET=bucket-value
STRIPE_KEY=stripe-value
STRIPE_SECRET=stripe-value-2
PLAID_SECRET=plaid-value
DB_LEGACY_DATABASE=legacy-value
PUSHER_APP_KEY=not-on-the-list'
  cd "$PARKED/ledger"
  run vhosty worktree add feature/x
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  assert_contains "$output" "still shared with ledger, as its .env has them: APP_ENV (production), FILESYSTEM_DISK (s3), AWS_BUCKET, STRIPE_*, PLAID_*, DB_LEGACY_DATABASE"
  [ "$(printf '%s\n' "$output" | grep -c 'still shared with ledger')" = 1 ]
  for v in bucket-value stripe-value plaid-value legacy-value not-on-the-list; do refute_contains "$output" "$v"; done
}

@test ".env: nothing risky, or only empty values, no warning" {
  repo_site ledger 'APP_ENV=local
DB_CONNECTION=sqlite
FILESYSTEM_DISK=local
AWS_BUCKET=
STRIPE_KEY=""
DB_LEGACY_DATABASE=null'
  cd "$PARKED/ledger"
  run vhosty worktree add feature/x
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  refute_contains "$output" "still shared"
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
  # vhosty's name for it, but it's what the parent uses now
  sed -i.bak 's/^DB_DATABASE=.*/DB_DATABASE=wt_x__ledger/' "$PARKED/ledger/.env"
  mysql_db wt_x__ledger
  site_conf x--ledger "SITE_PATH=$HOME/wt
SITE_LINKED=yes
SITE_WT_KIND=adopted
SITE_WT_PARENT=ledger
SITE_WT_REPO=$PARKED/ledger
SITE_WT_DB_KIND=mysql
SITE_WT_DB_SERVICE=mysql
SITE_WT_DB_NAME=wt_x__ledger"
  run vhosty worktree remove x--ledger --yes
  [ "$status" -ne 0 ]
  assert_contains "$output" "$PARKED/ledger/.env still names it"
  [ -e "$HOME/db/mysql/wt_x__ledger" ]
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
  assert_contains "$output" 'DROP DATABASE \`wt_feature_x__ledger\`'
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

# ---------------------------------------------------------------- what the review found

# with_mysql_worktree: ledger on MySQL, with the worktree feature-x--ledger and its database
with_mysql_worktree() {
  repo_site ledger "$MYSQL_ENV"
  services_on
  mysql_db ledger
  cd "$PARKED/ledger"
  run vhosty worktree add feature/x
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [ -e "$HOME/db/mysql/wt_feature_x__ledger" ]
}

# not_dropped REASON: refused before anything's touched, with a way out
not_dropped() {
  run vhosty worktree remove feature-x--ledger --yes
  [ "$status" -ne 0 ]
  assert_contains "$output" "$1"
  assert_contains "$output" "Nothing removed"
  assert_contains "$output" "--keep-db"
  [ -e "$HOME/db/mysql/wt_feature_x__ledger" ]
  [ -f "$VHOSTY_DIR/sites/feature-x--ledger.conf" ]
  [ -d "$VHOSTY_DIR/worktrees/ledger/feature-x" ]
  refute_contains "$(cat "$HOME/sql.log")" "DROP"
}

@test ".env: the last value of a key wins, as phpdotenv loads it" {
  printf 'A=first\nA=second\nB="x"\nB=\nexport C=1\n# C=2\n' >"$HOME/e"
  [ "$(vh worktree_env_get "$HOME/e" A)" = second ]
  [ -z "$(vh worktree_env_get "$HOME/e" B)" ]
  [ "$(vh worktree_env_get "$HOME/e" C)" = 1 ]
}

@test ".env: the search is blunt: any case, comments, longer names, every %XX, and only names the file" {
  cat >"$HOME/plain" <<'EOF'
DB_DATABASE=wt_x
EOF
  printf 'A=1\n# old WT_X here\n' >"$HOME/comment"
  printf 'B=my_wt_x_y\n' >"$HOME/longer"
  printf 'C=mysql://u:p@h/%%77%%74%%5F%%78\n' >"$HOME/encoded"
  printf 'D=mysql://u:p@h/%%2577t_x\n' >"$HOME/twice"
  printf 'E=wt_y\nF=wt-x\n' >"$HOME/none"
  out="$(vh worktree_text_names any wt_x "$HOME/plain" "$HOME/comment" "$HOME/longer" "$HOME/encoded" "$HOME/twice" "$HOME/none")"
  assert_contains "$out" "$HOME/plain"
  assert_contains "$out" "$HOME/comment"
  assert_contains "$out" "$HOME/longer"
  assert_contains "$out" "$HOME/encoded"
  assert_contains "$out" "$HOME/twice"
  refute_contains "$out" "$HOME/none"
  refute_contains "$out" "DB_DATABASE"
  # The whole word, for what a worktree's own .env keeps
  [ -z "$(vh worktree_text_names word wt_x "$HOME/longer")" ]
  [ -n "$(vh worktree_text_names word wt_x "$HOME/encoded")" ]
}

@test "remove: the parent's DB_URL names it: not dropped" {
  with_mysql_worktree
  echo 'DB_URL=mysql://u:p@127.0.0.1/wt_feature_x__ledger' >>"$PARKED/ledger/.env"
  not_dropped "$PARKED/ledger/.env still names it"
}

@test "remove: the parent's URL-encoded DATABASE_URL names it: not dropped" {
  with_mysql_worktree
  echo 'DATABASE_URL=mysql://u:p@127.0.0.1/wt%5Ffeature%5Fx%5F%5Fledger' >>"$PARKED/ledger/.env"
  not_dropped "$PARKED/ledger/.env still names it"
}

@test "remove: the parent's second DB_DATABASE names it: not dropped" {
  with_mysql_worktree
  echo 'DB_DATABASE=wt_feature_x__ledger' >>"$PARKED/ledger/.env"
  not_dropped "$PARKED/ledger/.env still names it"
}

@test "remove: the parent's first DB_DATABASE names it, a later one doesn't: still not dropped" {
  with_mysql_worktree
  { echo 'DB_DATABASE=wt_feature_x__ledger'; cat "$PARKED/ledger/.env"; } >"$HOME/e"
  cp "$HOME/e" "$PARKED/ledger/.env"
  not_dropped "$PARKED/ledger/.env still names it"
}

@test "remove: another key of the parent's names it: not dropped" {
  with_mysql_worktree
  echo 'DB_REPORTS_DATABASE=wt_feature_x__ledger' >>"$PARKED/ledger/.env"
  not_dropped "$PARKED/ledger/.env still names it"
}

@test "remove: a variable in the settings that pick a database can't be told: not dropped" {
  with_mysql_worktree
  echo 'DB_URL=mysql://h/${SOME_NAME}' >>"$PARKED/ledger/.env"
  not_dropped "from a variable"
}

@test "remove: the main checkout moved, so the parent's .env can't be read: not dropped, says how by hand" {
  with_mysql_worktree
  mv "$PARKED/ledger" "$HOME/moved"
  run vhosty worktree remove feature-x--ledger --yes
  [ "$status" -ne 0 ]
  assert_contains "$output" "isn't there"
  assert_contains "$output" "by hand"
  assert_contains "$output" "DROP DATABASE"
  assert_contains "$output" "--keep-db"
  [ -e "$HOME/db/mysql/wt_feature_x__ledger" ]
  [ -f "$VHOSTY_DIR/sites/feature-x--ledger.conf" ]
  refute_contains "$(cat "$HOME/sql.log")" "DROP"
}

@test "remove: an unreadable parent .env: not dropped" {
  [ "$(id -u)" != 0 ] || skip "root reads everything"
  with_mysql_worktree
  chmod 000 "$PARKED/ledger/.env"
  run vhosty worktree remove feature-x--ledger --yes
  chmod 644 "$PARKED/ledger/.env"
  [ "$status" -ne 0 ]
  assert_contains "$output" "can't be read"
  [ -e "$HOME/db/mysql/wt_feature_x__ledger" ]
}

@test "remove: a parent with no .env at all isn't a reason to keep it" {
  with_mysql_worktree
  rm "$PARKED/ledger/.env"
  run vhosty worktree remove feature-x--ledger --yes
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [ ! -e "$HOME/db/mysql/wt_feature_x__ledger" ]
}

@test "remove: a sibling worktree's .env names it: not dropped" {
  with_mysql_worktree
  git -C "$PARKED/ledger" worktree add -q "$HOME/sibling" -b sib
  printf 'DB_DATABASE=wt_feature_x__ledger\n' >"$HOME/sibling/.env"
  not_dropped "$HOME/sibling/.env still names it"
}

@test "remove: another site's .env names it: not dropped" {
  with_mysql_worktree
  php_site other
  printf 'DB_DATABASE=wt_feature_x__ledger\n' >"$PARKED/other/.env"
  not_dropped "$PARKED/other/.env still names it"
}

@test "remove: another site's record names it: not dropped" {
  with_mysql_worktree
  mkdir -p "$HOME/o"
  site_conf other--ledger "SITE_PATH=$HOME/o
SITE_LINKED=yes
SITE_WT_KIND=adopted
SITE_WT_PARENT=ledger
SITE_WT_REPO=$PARKED/ledger
SITE_WT_DB_KIND=mysql
SITE_WT_DB_SERVICE=mysql
SITE_WT_DB_NAME=wt_feature_x__ledger"
  not_dropped "the site other--ledger records it too"
}

@test "remove: a .env linked to the parent's doesn't hide what the parent says" {
  with_mysql_worktree
  echo 'DB_URL=mysql://h/wt_feature_x__ledger' >>"$PARKED/ledger/.env"
  ln -sf "$PARKED/ledger/.env" "$VHOSTY_DIR/worktrees/ledger/feature-x/.env"
  not_dropped "still names it"
}

@test "the drop itself refuses a name that isn't vhosty's, on its own" {
  repo_site ledger "$MYSQL_ENV"
  services_on
  mysql_db ledger
  refute vh worktree_db_drop mysql mysql ledger
  refute vh worktree_db_drop postgres postgres ledger
  [ ! -e "$HOME/docker.log" ]
  [ -e "$HOME/db/mysql/ledger" ]
}

@test "link: the parent's name in a worktree's .env counts by its last value" {
  repo_site ledger "$MYSQL_ENV"
  services_on
  git -C "$PARKED/ledger" worktree add -q "$HOME/wt" -b x
  { sed 's/^DB_DATABASE=.*/DB_DATABASE=agents_own/' "$PARKED/ledger/.env"; echo 'DB_DATABASE=ledger'; } >"$HOME/wt/.env"
  run vhosty worktree link "$HOME/wt"
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [ "$(vh worktree_env_get "$HOME/wt/.env" DB_DATABASE)" = wt_x__ledger ]
  refute grep -q '^DB_DATABASE=ledger' "$HOME/wt/.env"
  refute grep -q '^DB_DATABASE=agents_own' "$HOME/wt/.env"
}

@test "link: a worktree's own last value is its own, whatever came before" {
  repo_site ledger "$MYSQL_ENV"
  services_on
  mysql_db agents_own
  git -C "$PARKED/ledger" worktree add -q "$HOME/wt" -b x
  { cat "$PARKED/ledger/.env"; echo 'DB_DATABASE=agents_own'; } >"$HOME/wt/.env"
  run vhosty worktree link "$HOME/wt"
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  assert_contains "$output" "kept what its .env names (agents_own)"
  [ ! -e "$HOME/db/mysql/wt_x__ledger" ]
}

# ---- sqlite through links

# with_sqlite_link: the steps from the review, up to the link
with_sqlite_link() {
  repo_site ledger "$SQLITE_ENV"
  for e in "" -wal -shm -journal; do echo "parents$e" >"$PARKED/ledger/database/database.sqlite$e"; done
  git -C "$PARKED/ledger" worktree add -q -b ada "$HOME/ada"
  run vhosty worktree link "$HOME/ada"
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [ "$(conf_value ada--ledger SITE_WT_DB_NAME)" = "$HOME/ada/database/database.sqlite" ]
}

parents_files_intact() {
  for e in "" -wal -shm -journal; do [ "$(cat "$PARKED/ledger/database/database.sqlite$e")" = "parents$e" ]; done
}

@test "remove: database/ turned into a link to the parent's: its files survive" {
  with_sqlite_link
  mv "$HOME/ada/database" "$HOME/ada/database.orig"
  ln -s "$PARKED/ledger/database" "$HOME/ada/database"
  run vhosty worktree remove ada--ledger --yes
  [ "$status" -ne 0 ]
  assert_contains "$output" "Not deleting"
  assert_contains "$output" "nothing removed"
  parents_files_intact
  [ -f "$VHOSTY_DIR/sites/ada--ledger.conf" ]
  # --keep-db is the way out, and it doesn't delete them either
  run vhosty worktree remove ada--ledger --keep-db
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  parents_files_intact
  [ ! -f "$VHOSTY_DIR/sites/ada--ledger.conf" ]
}

@test "remove: the sqlite file turned into a link: refused" {
  with_sqlite_link
  rm "$HOME/ada/database/database.sqlite"
  ln -s "$PARKED/ledger/database/database.sqlite" "$HOME/ada/database/database.sqlite"
  run vhosty worktree remove ada--ledger --yes
  [ "$status" -ne 0 ]
  assert_contains "$output" "is a link"
  parents_files_intact
  [ -L "$HOME/ada/database/database.sqlite" ]
}

@test "remove: the sqlite file a link inside the worktree: refused, the other file stays" {
  with_sqlite_link
  echo other >"$HOME/ada/database/other.sqlite"
  rm "$HOME/ada/database/database.sqlite"
  ln -s other.sqlite "$HOME/ada/database/database.sqlite"
  run vhosty worktree remove ada--ledger --yes
  [ "$status" -ne 0 ]
  assert_contains "$output" "is a link"
  [ "$(cat "$HOME/ada/database/other.sqlite")" = other ]
}

@test "remove: database/ linked out of the worktree to somewhere else: refused" {
  with_sqlite_link
  mkdir -p "$HOME/elsewhere"
  echo mine >"$HOME/elsewhere/database.sqlite"
  mv "$HOME/ada/database" "$HOME/ada/database.orig"
  ln -s "$HOME/elsewhere" "$HOME/ada/database"
  run vhosty worktree remove ada--ledger --yes
  [ "$status" -ne 0 ]
  assert_contains "$output" "Not deleting"
  [ "$(cat "$HOME/elsewhere/database.sqlite")" = mine ]
}

@test "remove: the same file as the parent's, by a hard link: refused" {
  with_sqlite_link
  rm "$HOME/ada/database/database.sqlite"
  ln "$PARKED/ledger/database/database.sqlite" "$HOME/ada/database/database.sqlite"
  run vhosty worktree remove ada--ledger --yes
  [ "$status" -ne 0 ]
  assert_contains "$output" "is the file ledger's .env uses"
  [ -f "$HOME/ada/database/database.sqlite" ]
}

@test "remove: a sibling's .env naming the sqlite file: not deleted" {
  with_sqlite_link
  git -C "$PARKED/ledger" worktree add -q -b sib "$HOME/sib"
  printf 'DB_DATABASE=%s\n' "$HOME/ada/database/database.sqlite" >"$HOME/sib/.env"
  run vhosty worktree remove ada--ledger --yes
  [ "$status" -ne 0 ]
  assert_contains "$output" "still names it"
  [ -f "$HOME/ada/database/database.sqlite" ]
}

@test "remove: its own file, reached through a linked path to the worktree, still goes" {
  repo_site ledger "$SQLITE_ENV"
  git -C "$PARKED/ledger" worktree add -q -b ada "$HOME/real-ada"
  ln -s "$HOME/real-ada" "$HOME/ada"
  run vhosty worktree link "$HOME/ada"
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [ -f "$HOME/real-ada/database/database.sqlite" ]
  run vhosty worktree remove ada--ledger --yes
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [ ! -e "$HOME/real-ada/database/database.sqlite" ]
}

# ---- --keep-db for sqlite

@test "sqlite: --keep-db never touches an earlier kept copy, and picks a name of its own" {
  repo_site ledger "$SQLITE_ENV"
  cd "$PARKED/ledger"
  run vhosty worktree add feature/x
  [ "$status" -eq 0 ]
  mkdir -p "$VHOSTY_DIR/worktrees"
  echo earlier >"$VHOSTY_DIR/worktrees/feature-x--ledger.sqlite"
  echo migrated >"$VHOSTY_DIR/worktrees/ledger/feature-x/database/database.sqlite"
  run vhosty worktree remove feature-x--ledger --keep-db
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [ "$(cat "$VHOSTY_DIR/worktrees/feature-x--ledger.sqlite")" = earlier ]
  [ "$(cat "$VHOSTY_DIR/worktrees/feature-x--ledger.2.sqlite")" = migrated ]
  assert_contains "$output" "feature-x--ledger.2.sqlite"
  [ -z "$(find "$VHOSTY_DIR/worktrees" -name '.feature-x*')" ]
}

@test "sqlite: --keep-db when git refuses: the copy stays and is named, the earlier one too, and the file's where it was" {
  repo_site ledger "$SQLITE_ENV"
  cd "$PARKED/ledger"
  run vhosty worktree add feature/x
  [ "$status" -eq 0 ]
  wt="$VHOSTY_DIR/worktrees/ledger/feature-x"
  echo earlier >"$VHOSTY_DIR/worktrees/feature-x--ledger.sqlite"
  echo migrated >"$wt/database/database.sqlite"
  echo work >"$wt/uncommitted.txt"
  run vhosty worktree remove feature-x--ledger --keep-db
  [ "$status" -ne 0 ]
  assert_contains "$output" "Nothing was removed"
  [ "$(cat "$VHOSTY_DIR/worktrees/feature-x--ledger.sqlite")" = earlier ]
  [ "$(cat "$wt/database/database.sqlite")" = migrated ]
  [ -z "$(find "$VHOSTY_DIR/worktrees" -name '.feature-x*')" ]
  [ "$(cat "$VHOSTY_DIR/worktrees/feature-x--ledger.2.sqlite")" = migrated ]
  assert_contains "$output" "$VHOSTY_DIR/worktrees/feature-x--ledger.2.sqlite"
  [ -f "$VHOSTY_DIR/sites/feature-x--ledger.conf" ]
}

@test "sqlite: --keep-db copies no file through a link" {
  repo_site ledger "$SQLITE_ENV"
  echo parents-data >"$PARKED/ledger/database/database.sqlite"
  cd "$PARKED/ledger"
  run vhosty worktree add feature/x
  [ "$status" -eq 0 ]
  wt="$VHOSTY_DIR/worktrees/ledger/feature-x"
  rm "$wt/database/database.sqlite"
  ln -s "$PARKED/ledger/database/database.sqlite" "$wt/database/database.sqlite"
  run vhosty worktree remove feature-x--ledger --keep-db
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [ "$(cat "$PARKED/ledger/database/database.sqlite")" = parents-data ]
  [ -z "$(ls -A "$VHOSTY_DIR/worktrees")" ]
}

# ---- --copy-db on MySQL, and what it leaves alone

@test "mysql: --copy-db leaves out triggers, routines and events, and names them" {
  repo_site ledger "$MYSQL_ENV"
  services_on
  mysql_db ledger
  printf 'trigger audit_after_insert\nprocedure rollup\nevent nightly\n' >"$HOME/not-copied"
  cd "$PARKED/ledger"
  run vhosty worktree add feature/x --copy-db
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  assert_contains "$output" "not copied"
  assert_contains "$output" "trigger audit_after_insert, procedure rollup, event nightly"
  dump="$(cat "$HOME/dump.log")"
  assert_contains "$dump" "--skip-triggers"
  assert_contains "$dump" "--skip-routines"
  assert_contains "$dump" "--skip-events"
  refute_contains "$dump" " --routines"
  refute_contains "$dump" " --triggers"
  refute_contains "$dump" " --events"
  assert_contains "$(cat "$HOME/db/mysql/wt_feature_x__ledger")" "row of ledger"
  [ "$(cat "$HOME/db/mysql/ledger")" = "row of ledger" ]
  q="$(cat "$HOME/sql.log")"
  assert_contains "$q" "TRIGGER_SCHEMA = 'ledger'"
  refute_contains "$q" "load into ledger"
}

@test "mysql: nothing to leave out, no word about it" {
  repo_site ledger "$MYSQL_ENV"
  services_on
  mysql_db ledger
  cd "$PARKED/ledger"
  run vhosty worktree add feature/x --copy-db
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  refute_contains "$output" "not copied"
}

@test "mysql: a list of what's left out that can't be had is a warning, and it's still left out" {
  repo_site ledger "$MYSQL_ENV"
  services_on
  mysql_db ledger
  touch "$HOME/not-copied-fails"
  cd "$PARKED/ledger"
  run vhosty worktree add feature/x --copy-db
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  assert_contains "$output" "aren't copied"
  assert_contains "$(cat "$HOME/dump.log")" "--skip-triggers"
}

@test "postgres: a parent that can reach outside itself isn't copied: empty, recorded, exit 1, says why" {
  repo_site ledger "$PG_ENV"
  services_on
  pg_db ledger
  printf 'extension dblink\nforeign table remote_log\n' >"$HOME/reach"
  cd "$PARKED/ledger"
  run vhosty worktree add feature/x --copy-db
  [ "$status" -eq 1 ]
  assert_contains "$output" "not copying ledger"
  assert_contains "$output" "extension dblink"
  assert_contains "$output" "foreign table remote_log"
  assert_contains "$output" "stays empty"
  assert_contains "$output" "php artisan migrate --seed"
  [ ! -e "$HOME/dump.log" ]
  [ ! -s "$HOME/db/postgres/wt_feature_x__ledger" ]
  [ "$(conf_value feature-x--ledger SITE_WT_DB_NAME)" = wt_feature_x__ledger ]
}

@test "postgres: if that can't be checked, nothing's copied" {
  repo_site ledger "$PG_ENV"
  services_on
  pg_db ledger
  touch "$HOME/reach-fails"
  cd "$PARKED/ledger"
  run vhosty worktree add feature/x --copy-db
  [ "$status" -eq 1 ]
  assert_contains "$output" "couldn't check"
  [ ! -e "$HOME/dump.log" ]
  [ ! -s "$HOME/db/postgres/wt_feature_x__ledger" ]
}

@test "mysql: --set-gtid-purged only where the dump tool knows it (mariadb-dump doesn't)" {
  repo_site ledger "$MYSQL_ENV"
  services_on
  mysql_db ledger
  touch "$HOME/no-gtid-option"
  cd "$PARKED/ledger"
  run vhosty worktree add feature/x --copy-db
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  refute_contains "$(cat "$HOME/dump.log")" "gtid"
}

# ---- Postgres extensions

@test "postgres: an empty database gets the parent's extensions, each in its schema" {
  repo_site ledger "$PG_ENV"
  services_on
  pg_db ledger
  printf 'vector|public\npg_trgm|extensions\n' >"$HOME/extensions"
  cd "$PARKED/ledger"
  run vhosty worktree add feature/x
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  log="$(cat "$HOME/sql.log")"
  assert_contains "$log" "CREATE EXTENSION IF NOT EXISTS vector WITH SCHEMA public CASCADE"
  assert_contains "$log" 'CREATE SCHEMA IF NOT EXISTS extensions AUTHORIZATION "ledger_app"'
  assert_contains "$log" "CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA extensions CASCADE"
  refute_contains "$log" "CREATE SCHEMA IF NOT EXISTS public"
  assert_contains "$output" "php artisan migrate --seed"
}

@test "postgres: extensions it can't read are a warning, the database is still there" {
  repo_site ledger "$PG_ENV"
  services_on
  pg_db ledger
  touch "$HOME/ext-fails"
  cd "$PARKED/ledger"
  run vhosty worktree add feature/x
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  assert_contains "$output" "couldn't create ledger's extensions"
  [ -e "$HOME/db/postgres/wt_feature_x__ledger" ]
  [ "$(conf_value feature-x--ledger SITE_WT_DB_KIND)" = postgres ]
}

@test "postgres: --copy-db has the extensions before the load, and records the database" {
  repo_site ledger "$PG_ENV"
  services_on
  pg_db ledger
  echo 'CREATE SCHEMA extensions;' >>"$HOME/db/postgres/ledger"
  cd "$PARKED/ledger"
  run vhosty worktree add feature/x --copy-db
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [ "$(conf_value feature-x--ledger SITE_WT_DB_KIND)" = postgres ]
  [ "$(conf_value feature-x--ledger SITE_WT_DB_NAME)" = wt_feature_x__ledger ]
  assert_contains "$(cat "$HOME/db/postgres/wt_feature_x__ledger")" "CREATE SCHEMA IF NOT EXISTS extensions;"
  ext="$(grep -n 'CREATE EXTENSION' "$HOME/sql.log" | head -1 | cut -d: -f1)"
  load="$(grep -n 'load into wt_feature_x__ledger' "$HOME/sql.log" | head -1 | cut -d: -f1)"
  [ "$ext" -lt "$load" ]
}

# ---- remove, from inside

@test "remove from inside the worktree (created): the drop still works" {
  with_mysql_worktree
  cd "$VHOSTY_DIR/worktrees/ledger/feature-x"
  run vhosty worktree remove feature-x--ledger --yes
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [ ! -e "$HOME/db/mysql/wt_feature_x__ledger" ]
  assert_contains "$output" "dropped the mysql database"
  [ ! -f "$VHOSTY_DIR/sites/feature-x--ledger.conf" ]
}

@test "remove from a folder that's gone: still works" {
  with_mysql_worktree
  mkdir "$HOME/doomed"
  cd "$HOME/doomed"
  rmdir "$HOME/doomed"
  run vhosty worktree remove feature-x--ledger --yes
  cd "$HOME"
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [ ! -e "$HOME/db/mysql/wt_feature_x__ledger" ]
}

@test "remove: Octane stops before the database is dropped" {
  with_mysql_worktree
  run vh eval '
    svc_installed() { return 0; }
    svc_stop() { echo "STOPPED $1" >>"$HOME/sql.log"; }
    cmd_rebuild() { :; }
    site_load feature-x--ledger; SITE_OCTANE=on; site_save feature-x--ledger
    cmd_worktree_remove feature-x--ledger --yes'
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  stopped="$(grep -n 'STOPPED octane-feature-x--ledger' "$HOME/sql.log" | cut -d: -f1)"
  dropped="$(grep -n 'DROP DATABASE' "$HOME/sql.log" | cut -d: -f1)"
  [ -n "$stopped" ]
  [ -n "$dropped" ]
  [ "$stopped" -lt "$dropped" ]
}

# ---- relinking

@test "link, remove, link: the database is made again, and on record" {
  repo_site ledger "$MYSQL_ENV"
  services_on
  git -C "$PARKED/ledger" worktree add -q "$HOME/wt" -b x
  run vhosty worktree link "$HOME/wt"
  [ "$status" -eq 0 ]
  run vhosty worktree remove x--ledger --yes
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/db/mysql/wt_x__ledger" ]
  run vhosty worktree link "$HOME/wt"
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [ -e "$HOME/db/mysql/wt_x__ledger" ]
  [ "$(conf_value x--ledger SITE_WT_DB_NAME)" = wt_x__ledger ]
  assert_contains "$output" "new empty mysql database wt_x__ledger"
}

@test "link again after a create that failed: makes it" {
  repo_site ledger "$MYSQL_ENV"
  services_on
  touch "$HOME/create-fails"
  git -C "$PARKED/ledger" worktree add -q "$HOME/wt" -b x
  run vhosty worktree link "$HOME/wt"
  [ "$status" -ne 0 ]
  assert_contains "$output" "couldn't create wt_x__ledger"
  [ -z "$(conf_value x--ledger SITE_WT_DB_KIND)" ]
  rm "$HOME/create-fails"
  run vhosty worktree link "$HOME/wt"
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  assert_contains "$output" "already the worktree site"
  [ -e "$HOME/db/mysql/wt_x__ledger" ]
  [ "$(conf_value x--ledger SITE_WT_DB_NAME)" = wt_x__ledger ]
}

@test "link again with a database on record does nothing to it" {
  repo_site ledger "$MYSQL_ENV"
  services_on
  git -C "$PARKED/ledger" worktree add -q "$HOME/wt" -b x
  run vhosty worktree link "$HOME/wt"
  [ "$status" -eq 0 ]
  : >"$HOME/sql.log"
  run vhosty worktree link "$HOME/wt"
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [ ! -s "$HOME/sql.log" ]
}

@test "link: a name that isn't vhosty's shape and isn't there is a warning, not a new database" {
  repo_site ledger "$MYSQL_ENV"
  services_on
  git -C "$PARKED/ledger" worktree add -q "$HOME/wt" -b x
  sed 's/^DB_DATABASE=.*/DB_DATABASE=somebodys/' "$PARKED/ledger/.env" >"$HOME/wt/.env"
  run vhosty worktree link "$HOME/wt"
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  assert_contains "$output" "names somebodys, which isn't there"
  [ ! -e "$HOME/db/mysql/somebodys" ]
  refute_contains "$output" "kept what"
}

@test "link, remove, link on sqlite: the file is made again" {
  repo_site ledger "$SQLITE_ENV"
  git -C "$PARKED/ledger" worktree add -q "$HOME/wt" -b x
  run vhosty worktree link "$HOME/wt"
  [ "$status" -eq 0 ]
  run vhosty worktree remove x--ledger --yes
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/wt/database/database.sqlite" ]
  run vhosty worktree link "$HOME/wt"
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [ -f "$HOME/wt/database/database.sqlite" ]
  [ "$(conf_value x--ledger SITE_WT_DB_KIND)" = sqlite ]
}

# ---- what git refuses

@test "remove: a worktree with submodules says so, and how to do it by hand" {
  repo_site lib
  repo_site ledger "$SQLITE_ENV"
  git -C "$PARKED/ledger" -c protocol.file.allow=always submodule add -q "$PARKED/lib" lib
  git -C "$PARKED/ledger" commit -qm submodule
  cd "$PARKED/ledger"
  run vhosty worktree add feature/x
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  wt="$VHOSTY_DIR/worktrees/ledger/feature-x"
  git -C "$wt" -c protocol.file.allow=always submodule update -q --init
  run vhosty worktree remove feature-x--ledger --yes
  [ "$status" -ne 0 ]
  assert_contains "$output" "has submodules"
  assert_contains "$output" "worktree remove --force"
  refute_contains "$output" "uncommitted"
  assert_contains "$output" "Nothing was removed"
  [ -d "$wt" ]
  [ -f "$VHOSTY_DIR/sites/feature-x--ledger.conf" ]
}

@test "remove: a locked worktree says so" {
  with_mysql_worktree
  git -C "$PARKED/ledger" worktree lock "$VHOSTY_DIR/worktrees/ledger/feature-x"
  run vhosty worktree remove feature-x--ledger --yes
  [ "$status" -ne 0 ]
  assert_contains "$output" "is locked"
  assert_contains "$output" "worktree unlock"
  [ -e "$HOME/db/mysql/wt_feature_x__ledger" ]
}

@test "add: git still listing a folder that's gone: says what to run, and doesn't run it" {
  repo_site ledger "$SQLITE_ENV"
  cd "$PARKED/ledger"
  run vhosty worktree add feature/x
  [ "$status" -eq 0 ]
  wt="$VHOSTY_DIR/worktrees/ledger/feature-x"
  rm -rf "$wt"
  run vhosty prune --yes
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [ ! -e "$VHOSTY_DIR/sites/feature-x--ledger.conf" ]
  run vhosty worktree add feature/x
  [ "$status" -ne 0 ]
  assert_contains "$output" "worktree prune"
  assert_contains "$output" "affects every worktree"
  assert_contains "$(git -C "$PARKED/ledger" worktree list --porcelain)" "$wt"
}

# ---- drop hints

@test "the printed drop hints work as printed, and hold no password" {
  export MYSQL_ROOT_PASSWORD=hunter2secret
  [ "$(vh worktree_db_drop_hint sqlite x "/a b/c")" = 'rm -f /a\ b/c' ]
  mysql_db wt_a
  pg_db wt_b
  services_on
  h="$(vh worktree_db_drop_hint mysql mysql wt_a)"
  refute_contains "$h" hunter2secret
  eval "$h"
  [ ! -e "$HOME/db/mysql/wt_a" ]
  h="$(vh worktree_db_drop_hint postgres postgres wt_b)"
  eval "$h"
  [ ! -e "$HOME/db/postgres/wt_b" ]
}

# ---- backups

@test "backup skips exactly what worktree sites record, and says so" {
  mysql_db wt_ledger
  mysql_db wt_payroll
  mysql_db wt_x__ledger
  mysql_db wt_kept__ledger
  mysql_db wt_y__ledger
  pg_db books
  pg_db wt_money
  pg_db wt_z__books
  stub pg_dumpall 'echo roles'
  services_on
  rec() { # rec SITE KIND SERVICE NAME
    site_conf "$1" "SITE_PATH=$HOME/$1
SITE_LINKED=yes
SITE_WT_KIND=created
SITE_WT_PARENT=ledger
SITE_WT_REPO=$PARKED/ledger
SITE_WT_DB_KIND=$2
SITE_WT_DB_SERVICE=$3
SITE_WT_DB_NAME=$4"
  }
  rec x--ledger mysql mysql wt_x__ledger
  rec z--books postgres postgres wt_z__books
  # A hand-edited record names something else, on another service, or nothing
  rec odd--ledger mysql mysql wt_payroll
  rec y--ledger mysql mysql2 wt_y__ledger
  mkdir -p "$HOME/out/mysql" "$HOME/out/postgres"
  : >"$HOME/out/MANIFEST"
  run vh backup_mysql mysql "$HOME/out"
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  assert_contains "$output" "4 database(s) dumped (skipped test and worktree databases: wt_x__ledger)"
  run vh backup_postgres postgres "$HOME/out"
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  assert_contains "$output" "(skipped test and worktree databases: wt_z__books)"
  for db in wt_ledger wt_payroll wt_kept__ledger wt_y__ledger; do [ -f "$HOME/out/mysql/$db.sql.gz" ]; done
  [ -f "$HOME/out/postgres/wt_money.sql.gz" ]
  [ ! -e "$HOME/out/mysql/wt_x__ledger.sql.gz" ]
  [ ! -e "$HOME/out/postgres/wt_z__books.sql.gz" ]
  refute vh is_test_db wt_x
}

@test "restore: an old backup that has a worktree's database loads it like any other" {
  services_on
  mkdir -p "$HOME/old/config" "$HOME/old/mysql"
  printf 'services: {}\n' >"$HOME/old/config/compose.yaml"
  printf 'old row\n' | gzip >"$HOME/old/mysql/wt_old__ledger.sql.gz"
  printf 'created=2026-01-01\nhost=old\nmysql|mysql|wt_old__ledger|mysql/wt_old__ledger.sql.gz\n' >"$HOME/old/MANIFEST"
  run vhosty services restore "$HOME/old" --into "$HOME/svc" --yes
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  assert_contains "$output" "wt_old__ledger loaded"
  assert_contains "$(cat "$HOME/sql.log")" "load into (none): old row"
}

# ---------------------------------------------------------------- the .env it ends up with

# branch_with_env BRANCH TEXT: a branch that tracks a .env of its own
branch_with_env() {
  local d="$PARKED/ledger"
  [ ! -f "$d/.env" ] || cp "$d/.env" "$HOME/parent.env"
  git -C "$d" checkout -qb "$1"
  grep -v '^\.env$' "$d/.gitignore" >"$HOME/gitignore"
  cp "$HOME/gitignore" "$d/.gitignore"
  printf '%s\n' "$2" >"$d/.env"
  git -C "$d" add -f .env .gitignore
  git -C "$d" commit -qm cfg
  git -C "$d" checkout -q main
  [ ! -f "$HOME/parent.env" ] || cp "$HOME/parent.env" "$d/.env"
  cd "$d"
}

# undone BRANCH: stopped, with the worktree it made gone and nothing else made
undone() {
  [ "$status" -eq 1 ]
  [ ! -e "$VHOSTY_DIR/worktrees/ledger/$1" ]
  [ ! -e "$VHOSTY_DIR/sites/$1--ledger.conf" ]
  [ "$(git -C "$PARKED/ledger" worktree list | wc -l | tr -d ' ')" = 1 ]
  [ ! -e "$HOME/composer.log" ]
  assert_contains "$output" "removed the worktree"
  assert_contains "$output" "--share-db"
}

@test "add: a branch's own .env with a remote DB_URL is caught, and undone [A7]" {
  services_on
  repo_site ledger "$MYSQL_ENV"
  mysql_db ledger
  branch_with_env remote-cfg 'DB_CONNECTION=mysql
DB_URL=mysql://root:sekrit@prod.example.com:3306/ledger_prod'
  run vhosty worktree add remote-cfg --no-install
  undone remote-cfg
  assert_contains "$output" "database URL"
  refute_contains "$output" "sekrit"
  [ "$(ls "$HOME/db/mysql")" = ledger ]
  # It was there already, so nothing to say about the branch
  refute_contains "$output" "which this command created"
  git -C "$PARKED/ledger" show-ref --verify --quiet refs/heads/remote-cfg
}

@test "add: a branch's own .env with a remote host is caught, and --share-db lets it through [A7b]" {
  services_on
  repo_site ledger "$MYSQL_ENV"
  mysql_db ledger
  branch_with_env remote-cfg 'DB_CONNECTION=mysql
DB_HOST=prod.example.com
DB_DATABASE=ledger_prod'
  run vhosty worktree add remote-cfg --no-install
  undone remote-cfg
  assert_contains "$output" "prod.example.com"
  [ "$(ls "$HOME/db/mysql")" = ledger ]
  run vhosty worktree add remote-cfg --no-install --share-db
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  assert_contains "$(cat "$VHOSTY_DIR/worktrees/ledger/remote-cfg/.env")" "DB_HOST=prod.example.com"
  assert_contains "$(conf_value remote-cfg--ledger SITE_WT_DB_SHARED)" "prod.example.com"
}

@test "add: a .env.example only the branch has is what counts, with no .env in the parent [B4]" {
  services_on
  repo_site ledger
  cd "$PARKED/ledger"
  git checkout -qb remote-cfg
  printf 'DB_CONNECTION=mysql\nDB_HOST=prod.example.com\nDB_DATABASE=ledger_prod\n' >.env.example
  git add .env.example
  git commit -qm e
  git checkout -q main
  run vhosty worktree add remote-cfg --no-install
  undone remote-cfg
}

@test "add: a post-checkout hook's .env is caught, and a branch this made is said to stay" {
  services_on
  repo_site ledger "$MYSQL_ENV"
  mysql_db ledger
  cat >"$PARKED/ledger/.git/hooks/post-checkout" <<'EOF'
#!/bin/sh
printf 'DB_CONNECTION=mysql\nDB_HOST=prod.example.com\nDB_DATABASE=ledger_prod\n' >.env
EOF
  chmod +x "$PARKED/ledger/.git/hooks/post-checkout"
  cd "$PARKED/ledger"
  run vhosty worktree add hooked --no-install
  undone hooked
  assert_contains "$output" "The branch hooked, which this command created, stays"
  git -C "$PARKED/ledger" show-ref --verify --quiet refs/heads/hooked
  [ "$(ls "$HOME/db/mysql")" = ledger ]
}

@test "add: what git won't undo stays and is said, without --force" {
  services_on
  repo_site ledger "$MYSQL_ENV"
  mysql_db ledger
  cat >"$PARKED/ledger/.git/hooks/post-checkout" <<'EOF'
#!/bin/sh
printf 'DB_CONNECTION=mysql\nDB_HOST=prod.example.com\nDB_DATABASE=ledger_prod\n' >.env
echo draft >notes.txt
EOF
  chmod +x "$PARKED/ledger/.git/hooks/post-checkout"
  cd "$PARKED/ledger"
  run vhosty worktree add hooked --no-install
  [ "$status" -eq 1 ]
  assert_contains "$output" "git wouldn't remove the worktree"
  [ "$(cat "$VHOSTY_DIR/worktrees/ledger/hooked/notes.txt")" = draft ]
  [ ! -e "$VHOSTY_DIR/sites/hooked--ledger.conf" ]
  [ "$(ls "$HOME/db/mysql")" = ledger ]
}

@test "add: a branch's own .env on vhosty's service naming another database is fine" {
  services_on
  repo_site ledger "$MYSQL_ENV"
  mysql_db ledger
  mysql_db branchdb
  branch_with_env own-db 'DB_CONNECTION=mysql
DB_HOST=127.0.0.1
DB_DATABASE=branchdb'
  run vhosty worktree add own-db --no-install
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  assert_contains "$output" "kept what its .env names (branchdb)"
  [ -z "$(conf_value own-db--ledger SITE_WT_DB_KIND)" ]
}

# ---------------------------------------------------------------- --keep-db, and git failing partway

# sqlite_precious: a worktree whose sqlite file holds the only copy of something
sqlite_precious() {
  repo_site ledger "$SQLITE_ENV"
  cd "$PARKED/ledger"
  printf 'storage/\n' >>.gitignore
  git add .gitignore
  git commit -qm i
  run vhosty worktree add x --no-install
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  W="$VHOSTY_DIR/worktrees/ledger/x"
  echo precious >"$W/database/database.sqlite"
  cd /
}

# stub_git_partway: git deletes database/ and then fails, as it can
stub_git_partway() {
  local real
  real="$(command -v git)"
  stub git "case \"\$*\" in *'worktree remove'*) rm -rf \"$W/database\"; echo 'error: failed to delete' >&2; exit 1 ;; esac; exec \"$real\" \"\$@\""
}

@test "keep-db: git fails partway: the copy is safe, and it doesn't say nothing was removed [P1]" {
  sqlite_precious
  stub_git_partway
  run vhosty worktree remove x--ledger --keep-db
  [ "$status" -ne 0 ]
  refute_contains "$output" "Nothing was removed"
  assert_contains "$output" "files may be gone"
  assert_contains "$output" "What's left there"
  assert_contains "$output" "public"
  assert_contains "$output" "$VHOSTY_DIR/worktrees/x--ledger.sqlite"
  [ "$(cat "$VHOSTY_DIR/worktrees/x--ledger.sqlite")" = precious ]
  [ -f "$VHOSTY_DIR/sites/x--ledger.conf" ]
}

@test "keep-db: real git on a read-only folder: the copy is safe, whatever got deleted [P1]" {
  sqlite_precious
  mkdir -p "$W/storage/logs"
  echo l >"$W/storage/logs/laravel.log"
  chmod 555 "$W/storage/logs"
  mv "$W/database" "$W/database.tmp"
  mv "$W/database.tmp" "$W/database"
  # Asks first without --yes, as storage/ goes with it
  run vhosty worktree remove x--ledger --keep-db </dev/null
  [ "$status" -ne 0 ]
  assert_contains "$output" "storage/"
  [ "$(cat "$W/database/database.sqlite")" = precious ]
  run vhosty worktree remove x--ledger --keep-db --yes </dev/null
  chmod -R u+w "$W"
  [ "$status" -ne 0 ]
  [ "$(cat "$VHOSTY_DIR/worktrees/x--ledger.sqlite")" = precious ]
  [ -f "$VHOSTY_DIR/sites/x--ledger.conf" ]
  if [ -e "$W/database/database.sqlite" ] && [ -e "$W/.env" ]; then :; else
    refute_contains "$output" "Nothing was removed"
    assert_contains "$output" "files may be gone"
  fi
}

@test "remove: git fails partway on mysql: says so, keeps the database and the record [P2]" {
  with_mysql_worktree
  W="$VHOSTY_DIR/worktrees/ledger/feature-x"
  stub_git_partway
  run vhosty worktree remove feature-x--ledger --yes
  [ "$status" -ne 0 ]
  refute_contains "$output" "Nothing was removed"
  assert_contains "$output" "files may be gone"
  [ -e "$HOME/db/mysql/wt_feature_x__ledger" ]
  [ -f "$VHOSTY_DIR/sites/feature-x--ledger.conf" ]
}

@test "keep-db: killed during the Octane stop, after git: the copy is safe [S1]" {
  sqlite_precious
  run vh eval 'svc_installed() { return 0; }; cmd_rebuild() { :; }; svc_stop() { kill -TERM $$; sleep 1; }
    site_load x--ledger; SITE_OCTANE=on; site_save x--ledger; cmd_worktree_remove x--ledger --keep-db'
  [ "$(cat "$VHOSTY_DIR/worktrees/x--ledger.sqlite")" = precious ]
}

@test "keep-db: killed straight after git: the copy is safe [B1t]" {
  sqlite_precious
  real="$(command -v git)"
  stub git "\"$real\" \"\$@\"; rc=\$?; case \"\$*\" in *'worktree remove'*) kill -TERM \$PPID; sleep 1 ;; esac; exit \$rc"
  run vhosty worktree remove x--ledger --keep-db
  [ "$(cat "$VHOSTY_DIR/worktrees/x--ledger.sqlite")" = precious ]
}

@test "keep-db: a file it can't copy stops it before the folder is touched" {
  sqlite_precious
  mkdir -p "$VHOSTY_DIR/worktrees"
  stub cp 'exit 1'
  run vhosty worktree remove x--ledger --keep-db
  [ "$status" -ne 0 ]
  assert_contains "$output" "nothing was removed"
  [ "$(cat "$W/database/database.sqlite")" = precious ]
}

# ---------------------------------------------------------------- what counts as managed

# plan_says LINE [refused text]: the parent's .env with LINE added, and what add makes of it
plan_refused() {
  cp "$HOME/o" "$PARKED/ledger/.env"
  printf '%b\n' "$1" >>"$PARKED/ledger/.env"
  run vhosty worktree add z --no-install
  [ "$status" -eq 1 ]
  assert_contains "$output" "${2:-would share}"
  assert_contains "$output" "Nothing changed"
  [ ! -e "$VHOSTY_DIR/worktrees/ledger/z" ]
}
plan_managed() {
  cp "$HOME/o" "$PARKED/ledger/.env"
  [ -z "$1" ] || printf '%b\n' "$1" >>"$PARKED/ledger/.env"
  run vhosty worktree add z --no-install
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  assert_contains "$output" "new empty mysql database wt_z__ledger"
  run vhosty worktree remove z--ledger --yes
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
}

@test "managed means 127.0.0.1 and nothing else [B14]" {
  services_on
  repo_site ledger "$MYSQL_ENV"
  mysql_db ledger
  cp "$PARKED/ledger/.env" "$HOME/o"
  cd "$PARKED/ledger"
  plan_refused 'export DB_HOST=prod.example.com'
  plan_refused 'DB_HOST="prod.example.com" # c'
  plan_refused 'DB_HOST = prod.example.com'
  plan_refused 'DB_HOST=prod.example.com\r'
  plan_refused 'DB_HOST=127.0.0.2'
  plan_refused 'DB_HOST=0.0.0.0'
  plan_refused 'DB_HOST=host.docker.internal'
  plan_refused 'DB_HOST=::1'
  plan_refused 'DB_HOST=[::1]'
  plan_refused 'DB_HOST=' 'empty'
  plan_refused 'DB_HOST=localhost' 'Use DB_HOST=127.0.0.1'
  plan_refused 'DB_SOCKET=/tmp/mysql.sock' 'DB_SOCKET'
  plan_refused 'DB_READ_HOST=prod.example.com' 'DB_READ_HOST'
  plan_refused 'DB_WRITE_HOST=127.0.0.1' 'DB_WRITE_HOST'
  plan_refused 'DATABASE_URL=mysql://u:p@h/x' 'database URL'
  plan_refused 'DB_PORT=13306' 'no vhosty docker service'
  plan_refused 'DB_PORT="13306"' 'no vhosty docker service'
  plan_managed ''
  plan_managed 'DB_HOST="127.0.0.1"'
  plan_managed 'export DB_HOST=127.0.0.1'
  plan_managed 'DB_HOST=127.0.0.1\r'
  plan_managed 'DB_URL='
  plan_managed 'DB_READ_HOST='
  # No key at all is what Laravel takes for 127.0.0.1
  grep -v '^DB_HOST=' "$HOME/o" >"$HOME/o2"
  mv "$HOME/o2" "$HOME/o"
  plan_managed ''
}

@test "managed: localhost stops on postgres too" {
  services_on
  repo_site ledger "$PG_ENV
DB_HOST=localhost"
  pg_db ledger
  cd "$PARKED/ledger"
  run vhosty worktree add z --no-install
  [ "$status" -eq 1 ]
  assert_contains "$output" "Use DB_HOST=127.0.0.1"
  [ ! -e "$HOME/db/postgres/wt_z__ledger" ]
}

@test "managed: the running container has to publish that port on 127.0.0.1, whatever compose.yaml says [T2]" {
  services_on
  repo_site ledger "$MYSQL_ENV"
  mysql_db ledger
  cd "$PARKED/ledger"
  # An edit to compose.yaml that hasn't been applied: something else is on that port
  cat >"$HOME/ps.json" <<'JSON'
{"Service":"mysql","Image":"mysql:8.4","State":"running","Publishers":[{"URL":"127.0.0.1","TargetPort":3306,"PublishedPort":3307}]}
JSON
  run vhosty worktree add z --no-install
  [ "$status" -eq 1 ]
  assert_contains "$output" "no running container does"
  assert_contains "$output" "vhosty services up mysql"
  [ ! -e "$HOME/db/mysql/wt_z__ledger" ]
  # On another address only
  cat >"$HOME/ps.json" <<'JSON'
{"Service":"mysql","Image":"mysql:8.4","State":"running","Publishers":[{"URL":"192.168.1.5","TargetPort":3306,"PublishedPort":3306}]}
JSON
  run vhosty worktree add z --no-install
  [ "$status" -eq 1 ]
  # Stopped, with its row still there
  cat >"$HOME/ps.json" <<'JSON'
{"Service":"mysql","Image":"mysql:8.4","State":"exited","Publishers":[]}
JSON
  run vhosty worktree add z --no-install
  [ "$status" -eq 1 ]
  assert_contains "$output" "Start it"
  # Listed, but not running, with the port still shown
  cat >"$HOME/ps.json" <<'JSON'
{"Service":"mysql","Image":"mysql:8.4","State":"restarting","Publishers":[{"URL":"127.0.0.1","TargetPort":3306,"PublishedPort":3306}]}
JSON
  run vhosty worktree add z --no-install
  [ "$status" -eq 1 ]
  # On all addresses, 127.0.0.1 is one of them
  cat >"$HOME/ps.json" <<'JSON'
{"Service":"mysql","Image":"mysql:8.4","State":"running","Publishers":[{"URL":"0.0.0.0","TargetPort":3306,"PublishedPort":3306},{"URL":"::","TargetPort":3306,"PublishedPort":3306}]}
JSON
  run vhosty worktree add z --no-install
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
}

@test "managed: a port held by a service of the wrong kind isn't it" {
  services_on
  repo_site ledger "$PG_ENV
DB_PORT=3306"
  pg_db ledger
  cd "$PARKED/ledger"
  run vhosty worktree add z --no-install
  [ "$status" -eq 1 ]
  assert_contains "$output" "no vhosty docker service publishes postgres"
}

# ---------------------------------------------------------------- a worktree's own .env

# wt_with_env TEXT: an adopted worktree y, with its own .env
wt_with_env() {
  git -C "$PARKED/ledger" worktree add -q -b y "$HOME/wty"
  printf '%s\n' "$1" >"$HOME/wty/.env"
  cd "$HOME/wty"
}
OWN_ENV='DB_CONNECTION=mysql
DB_HOST=127.0.0.1
DB_PORT=3306'

@test "link: a .env naming what the parent reaches by DB_URL gets its own [A6]" {
  services_on
  repo_site ledger "DB_CONNECTION=mysql
DB_URL=mysql://root:p@127.0.0.1:3306/ledger"
  mysql_db ledger
  # The parent's own plan isn't what's asked about here: its URL stops an add, not this
  wt_with_env "$OWN_ENV
DB_DATABASE=ledger"
  run vhosty worktree link --no-install
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  assert_contains "$(cat .env)" "DB_DATABASE=wt_y__ledger"
  [ -e "$HOME/db/mysql/wt_y__ledger" ]
  [ "$(conf_value y--ledger SITE_WT_DB_NAME)" = wt_y__ledger ]
}

@test "link: a .env naming what the parent's \${VAR} comes to gets its own [A6b]" {
  services_on
  repo_site ledger 'APP_SLUG=ledger
DB_CONNECTION=mysql
DB_HOST=127.0.0.1
DB_DATABASE=${APP_SLUG}'
  mysql_db ledger
  wt_with_env "$OWN_ENV
DB_DATABASE=ledger"
  run vhosty worktree link --no-install
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  assert_contains "$(cat .env)" "DB_DATABASE=wt_y__ledger"
}

@test "link: a .env naming the parent's database in capitals gets its own [L2]" {
  services_on
  repo_site ledger "$MYSQL_ENV"
  mysql_db ledger
  wt_with_env "$OWN_ENV
DB_DATABASE=LEDGER"
  run vhosty worktree link --no-install
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  assert_contains "$(cat .env)" "DB_DATABASE=wt_y__ledger"
}

@test "link: when the parent's database can't be worked out, it stops, unless --share-db" {
  services_on
  repo_site ledger 'DB_CONNECTION=mysql
DB_HOST=127.0.0.1
DB_DATABASE=${NOT_SET}'
  mysql_db other
  wt_with_env "$OWN_ENV
DB_DATABASE=other"
  run vhosty worktree link --no-install
  [ "$status" -eq 1 ]
  assert_contains "$output" "can't tell"
  [ ! -e "$VHOSTY_DIR/sites/y--ledger.conf" ] || [ -z "$(conf_value y--ledger SITE_WT_DB_KIND)" ]
  # Its own .env is what it asked to keep
  run vhosty worktree link --no-install --share-db
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  assert_contains "$(cat .env)" "DB_DATABASE=other"
}

@test "link: with no .env in the parent, it stops, unless --share-db" {
  services_on
  repo_site ledger
  mysql_db other
  wt_with_env "$OWN_ENV
DB_DATABASE=other"
  run vhosty worktree link --no-install
  [ "$status" -eq 1 ]
  assert_contains "$output" "can't tell"
  run vhosty worktree link --no-install --share-db
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
}

@test "link: vhosty's own name is kept, with or without a parent's .env, and made if missing" {
  services_on
  repo_site ledger
  wt_with_env "$OWN_ENV
DB_DATABASE=wt_y__ledger"
  run vhosty worktree link --no-install
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [ -e "$HOME/db/mysql/wt_y__ledger" ]
  [ "$(conf_value y--ledger SITE_WT_DB_NAME)" = wt_y__ledger ]
}

@test "link: another wt_ name that's missing isn't made" {
  services_on
  repo_site ledger "$MYSQL_ENV"
  mysql_db ledger
  wt_with_env "$OWN_ENV
DB_DATABASE=wt_someone_else"
  run vhosty worktree link --no-install
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  assert_contains "$output" "isn't there"
  [ ! -e "$HOME/db/mysql/wt_someone_else" ]
  [ -z "$(conf_value y--ledger SITE_WT_DB_KIND)" ]
}

@test "link --copy-db on a site that already has its database is an error [A8]" {
  services_on
  repo_site ledger "$MYSQL_ENV"
  mysql_db ledger
  cd "$PARKED/ledger"
  run vhosty worktree add s --no-install --share-db
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  run vhosty worktree link "$VHOSTY_DIR/worktrees/ledger/s" --copy-db --no-install
  [ "$status" -ne 0 ]
  assert_contains "$output" "--copy-db can't do anything here"
  assert_contains "$output" "vhosty worktree remove s--ledger"
  [ ! -e "$HOME/dump.log" ]
  run vhosty worktree add r --no-install
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  run vhosty worktree link "$VHOSTY_DIR/worktrees/ledger/r" --copy-db --no-install
  [ "$status" -ne 0 ]
  assert_contains "$output" "--copy-db can't do anything here"
  # Without it, running it again is still fine
  run vhosty worktree link "$VHOSTY_DIR/worktrees/ledger/r" --no-install
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
}

# ---------------------------------------------------------------- the drop guard

@test "guard: any %XX in the parent's URL, any number of times [A3]" {
  with_mysql_worktree
  printf '\nDB_URL=mysql://root:p@127.0.0.1:3306/%%77t_feature_x__ledger\n' >>"$PARKED/ledger/.env"
  not_dropped "$PARKED/ledger/.env still names it"
  sed -i.bak '$d' "$PARKED/ledger/.env"
  printf 'X=%%2577t%%255Ffeature_x__ledger\n' >>"$PARKED/ledger/.env"
  not_dropped "$PARKED/ledger/.env still names it"
}

@test "guard: in capitals [A4], in a comment, under any key" {
  with_mysql_worktree
  cp "$PARKED/ledger/.env" "$HOME/o"
  for line in 'DB_DATABASE=WT_FEATURE_X__LEDGER' '# old: wt_feature_x__ledger' 'NOTES=wt_feature_x__ledger'; do
    cp "$HOME/o" "$PARKED/ledger/.env"
    printf '%s\n' "$line" >>"$PARKED/ledger/.env"
    not_dropped "$PARKED/ledger/.env still names it"
    refute_contains "$output" "hunter2secret"
  done
}

@test "guard: the parent's .env.local or .env.testing [A5]" {
  with_mysql_worktree
  printf 'DB_DATABASE=wt_feature_x__ledger\n' >"$PARKED/ledger/.env.local"
  not_dropped "$PARKED/ledger/.env.local still names it"
  rm "$PARKED/ledger/.env.local"
  printf 'DB_DATABASE=wt_feature_x__ledger\n' >"$PARKED/ledger/.env.testing"
  not_dropped "$PARKED/ledger/.env.testing still names it"
}

@test "guard: a parked sibling that can't be read can't be told [A2]" {
  with_mysql_worktree
  mkdir -p "$PARKED/other"
  printf 'DB_DATABASE=wt_feature_x__ledger\n' >"$PARKED/other/.env"
  chmod 000 "$PARKED/other"
  not_dropped "$PARKED/other can't be read"
  chmod 755 "$PARKED/other"
  chmod 000 "$PARKED/other/.env"
  not_dropped "$PARKED/other/.env can't be read"
  assert_contains "$output" "DROP DATABASE"
  chmod 644 "$PARKED/other/.env"
}

@test "guard: a parent folder that can't be read can't be told, with a worktree outside it [A2d]" {
  services_on
  repo_site ledger "$MYSQL_ENV"
  mysql_db ledger
  git -C "$PARKED/ledger" worktree add -q -b x "$HOME/wtx"
  cd "$HOME/wtx"
  run vhosty worktree link --no-install
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  cd /
  chmod 000 "$PARKED/ledger"
  run vhosty worktree remove x--ledger --yes
  chmod 755 "$PARKED/ledger"
  [ "$status" -ne 0 ]
  assert_contains "$output" "can't be read"
  [ -e "$HOME/db/mysql/wt_x__ledger" ]
  [ -f "$VHOSTY_DIR/sites/x--ledger.conf" ]
}

@test "guard: a dangling link for a .env can't be told" {
  with_mysql_worktree
  mkdir -p "$PARKED/other"
  ln -s /nonexistent/env "$PARKED/other/.env"
  not_dropped "$PARKED/other/.env can't be read"
}

@test "guard: a sibling site that's absent is skipped with a note, and the drop goes on [B9b]" {
  with_mysql_worktree
  site_conf other "SITE_PATH=$HOME/disk/other
SITE_LINKED=yes"
  run vhosty worktree remove feature-x--ledger --yes
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  assert_contains "$output" "not checking $HOME/disk/other"
  [ ! -e "$HOME/db/mysql/wt_feature_x__ledger" ]
}

@test "guard: variables in the parent's database keys: resolved, or can't tell [B9]" {
  with_mysql_worktree
  cp "$PARKED/ledger/.env" "$HOME/o"
  for line in 'DB_DATABASE=${NOT_SET}' 'DB_DATABASE=$NOT_SET' 'DB_URL=mysql://h/${NOT_SET}' 'DATABASE_URL=${NOT_SET}' 'DB_REPORTS_DATABASE=${NOT_SET}' 'DB_DATABASE=${A}${NOT_SET}'; do
    cp "$HOME/o" "$PARKED/ledger/.env"
    printf '%s\n' "$line" >>"$PARKED/ledger/.env"
    not_dropped "from a variable"
  done
  # Resolved, and comes to this one
  cp "$HOME/o" "$PARKED/ledger/.env"
  printf 'P=wt_feature_x\nDB_DATABASE="${P}__ledger"\n' >>"$PARKED/ledger/.env"
  not_dropped "$PARKED/ledger/.env still names it"
  # Resolved, and comes to something else
  cp "$HOME/o" "$PARKED/ledger/.env"
  printf 'P=books\nDB_DATABASE="${P}"\n' >>"$PARKED/ledger/.env"
  run vhosty worktree remove feature-x--ledger --yes
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
}

@test "guard: a password with a \$ in it isn't a reason to refuse" {
  with_mysql_worktree
  printf 'DB_PASSWORD=pa$$word${x}\n' >>"$PARKED/ledger/.env"
  run vhosty worktree remove feature-x--ledger --yes
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
}

# ---------------------------------------------------------------- the record

@test "drop: only vhosty's own name for this site, whatever the record says [A13]" {
  with_mysql_worktree
  mysql_db wt_payroll
  sed -i.bak 's/^SITE_WT_DB_NAME=.*/SITE_WT_DB_NAME=wt_payroll/' "$VHOSTY_DIR/sites/feature-x--ledger.conf"
  run vhosty worktree remove feature-x--ledger --yes
  [ "$status" -ne 0 ]
  assert_contains "$output" "isn't the name vhosty gives this site"
  assert_contains "$output" "--keep-db"
  [ -e "$HOME/db/mysql/wt_payroll" ]
  refute_contains "$(cat "$HOME/sql.log")" "DROP"
  # And the function itself, for anything that gets that far
  refute vh worktree_db_drop mysql mysql wt_payroll feature-x--ledger
  refute vh worktree_db_drop mysql mysql wt_payroll
  [ -e "$HOME/db/mysql/wt_payroll" ]
  vh worktree_db_drop mysql mysql wt_feature_x__ledger feature-x--ledger
  [ ! -e "$HOME/db/mysql/wt_feature_x__ledger" ]
}

@test "drop: a parent really called wt_something, recorded by hand, stays [G1]" {
  services_on
  repo_site ledger 'DB_CONNECTION=mysql
DB_HOST=127.0.0.1
DB_DATABASE=wt_ledger_live'
  mysql_db wt_ledger_live
  cd "$PARKED/ledger"
  run vhosty worktree add x --no-install
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  cd /
  sed -i.bak 's/^SITE_WT_DB_NAME=.*/SITE_WT_DB_NAME=wt_ledger_live/' "$VHOSTY_DIR/sites/x--ledger.conf"
  run vhosty worktree remove x--ledger --yes
  [ "$status" -ne 0 ]
  [ -e "$HOME/db/mysql/wt_ledger_live" ]
}

# ---------------------------------------------------------------- where it all points now

@test "remove: a created folder replaced by a link to a sibling: refused, and doesn't blame uncommitted files [A12]" {
  repo_site ledger "$SQLITE_ENV"
  cd "$PARKED/ledger"
  run vhosty worktree add x --no-install
  run vhosty worktree add y --no-install
  X="$VHOSTY_DIR/worktrees/ledger/x"
  Y="$VHOSTY_DIR/worktrees/ledger/y"
  echo ydata >"$Y/database/database.sqlite"
  mv "$X" "$HOME/xmoved"
  ln -s "$Y" "$X"
  cd /
  for flag in --yes --keep-db; do
    run vhosty worktree remove x--ledger "$flag"
    [ "$status" -ne 0 ]
    assert_contains "$output" "now resolves to $Y"
    refute_contains "$output" "uncommitted"
    [ "$(cat "$Y/database/database.sqlite")" = ydata ]
    [ -f "$VHOSTY_DIR/sites/x--ledger.conf" ]
  done
}

@test "remove: an adopted folder replaced by a link to a sibling, or the parent: refused [A12b, A12c, A12d]" {
  services_on
  repo_site ledger "$MYSQL_ENV"
  mysql_db ledger
  git -C "$PARKED/ledger" worktree add -q -b x "$HOME/wtx"
  cd "$HOME/wtx"
  run vhosty worktree link --no-install
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  cd /
  mv "$HOME/wtx" "$HOME/xmoved"
  ln -s "$PARKED/ledger" "$HOME/wtx"
  printf '\nDB_URL=mysql://r:p@127.0.0.1/wt_x__ledger\n' >>"$PARKED/ledger/.env"
  run vhosty worktree remove x--ledger --yes
  [ "$status" -ne 0 ]
  assert_contains "$output" "now resolves to $PARKED/ledger"
  [ -e "$HOME/db/mysql/wt_x__ledger" ]
}

@test "remove: database/ swapped for a link at the prompt: the parent's file stays [B2]" {
  repo_site ledger "$SQLITE_ENV"
  echo pdata >"$PARKED/ledger/database/database.sqlite"
  git -C "$PARKED/ledger" worktree add -q -b x "$HOME/wtx"
  cd "$HOME/wtx"
  run vhosty worktree link --no-install
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  cd /
  export PARKED
  run vh eval '
    confirm() { mv "$HOME/wtx/database" "$HOME/wtx/database.old"; ln -s "$PARKED/ledger/database" "$HOME/wtx/database"; return 0; }
    has_tty() { return 0; }; cmd_rebuild() { :; }
    cmd_worktree_remove x--ledger'
  [ "$status" -ne 0 ]
  assert_contains "$output" "is a link"
  [ "$(cat "$PARKED/ledger/database/database.sqlite")" = pdata ]
  [ -f "$VHOSTY_DIR/sites/x--ledger.conf" ]
}

@test "remove: the folder swapped for a link at the prompt: refused" {
  repo_site ledger "$SQLITE_ENV"
  echo pdata >"$PARKED/ledger/database/database.sqlite"
  git -C "$PARKED/ledger" worktree add -q -b x "$HOME/wtx"
  cd "$HOME/wtx"
  run vhosty worktree link --no-install
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  cd /
  export PARKED
  run vh eval '
    confirm() { mv "$HOME/wtx" "$HOME/xmoved"; ln -s "$PARKED/ledger" "$HOME/wtx"; return 0; }
    has_tty() { return 0; }; cmd_rebuild() { :; }
    cmd_worktree_remove x--ledger'
  [ "$status" -ne 0 ]
  assert_contains "$output" "now resolves to"
  [ "$(cat "$PARKED/ledger/database/database.sqlite")" = pdata ]
}

@test "remove: the record is the physical path, even from a linked path" {
  repo_site ledger "$SQLITE_ENV"
  git -C "$PARKED/ledger" worktree add -q -b x "$HOME/wtx"
  ln -s "$HOME/wtx" "$HOME/alias"
  run vhosty worktree link "$HOME/alias" --no-install
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [ "$(conf_value x--ledger SITE_WT_REAL)" = "$HOME/wtx" ]
  run vhosty worktree remove x--ledger --yes
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
}

# ---------------------------------------------------------------- what goes with the folder

@test "remove: ignored files are listed and asked about, vendor and friends left out [A17]" {
  repo_site ledger "$MYSQL_ENV"
  cd "$PARKED/ledger"
  printf 'storage/app/\nnode_modules/\n' >>.gitignore
  git add .gitignore
  git commit -qm i
  run vhosty worktree add s --no-install --share-db
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  W="$VHOSTY_DIR/worktrees/ledger/s"
  mkdir -p "$W/storage/app" "$W/vendor/x" "$W/node_modules/y"
  echo receipt >"$W/storage/app/receipt.pdf"
  echo v >"$W/vendor/x/v"
  echo n >"$W/node_modules/y/n"
  cd /
  run vhosty worktree remove s--ledger </dev/null
  [ "$status" -ne 0 ]
  assert_contains "$output" "storage/"
  refute_contains "$output" "vendor"
  refute_contains "$output" "node_modules"
  assert_contains "$output" "no terminal"
  [ "$(cat "$W/storage/app/receipt.pdf")" = receipt ]
  run vhosty worktree remove s--ledger --yes </dev/null
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  assert_contains "$output" "storage/"
  [ ! -e "$W" ]
}

@test "remove: nothing but what can be rebuilt asks nothing" {
  repo_site ledger "$SQLITE_ENV"
  cd "$PARKED/ledger"
  run vhosty worktree add s --no-install --share-db
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  W="$VHOSTY_DIR/worktrees/ledger/s"
  mkdir -p "$W/vendor/x"
  echo v >"$W/vendor/x/v"
  cd /
  run vhosty worktree remove s--ledger </dev/null
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  refute_contains "$output" "Ignored files"
}

@test "remove: a long list of ignored files says how many more" {
  repo_site ledger "$SQLITE_ENV"
  cd "$PARKED/ledger"
  printf 'up*\n' >>.gitignore
  git add .gitignore
  git commit -qm i
  run vhosty worktree add s --no-install --share-db
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  W="$VHOSTY_DIR/worktrees/ledger/s"
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13; do echo x >"$W/up$i"; done
  cd /
  run vhosty worktree remove s--ledger --yes
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  assert_contains "$output" "and 3 more"
}

@test "remove: no database settings: Laravel's default file counts [B3]" {
  repo_site ledger 'APP_KEY=base64:x
APP_NAME=Ledger'
  cd "$PARKED/ledger"
  run vhosty worktree add x --no-install
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  W="$VHOSTY_DIR/worktrees/ledger/x"
  [ ! -e "$W/database/database.sqlite" ]
  echo appdata >"$W/database/database.sqlite"
  cd /
  run vhosty worktree remove x--ledger </dev/null
  [ "$status" -ne 0 ]
  assert_contains "$output" "database/database.sqlite"
  [ "$(cat "$W/database/database.sqlite")" = appdata ]
  run vhosty worktree remove x--ledger --keep-db </dev/null
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [ "$(cat "$VHOSTY_DIR/worktrees/x--ledger.sqlite")" = appdata ]
  assert_contains "$output" "$VHOSTY_DIR/worktrees/x--ledger.sqlite"
  [ ! -e "$W" ]
}

@test "remove: --keep-db saves the file .env really names, not just the one on record [A10]" {
  repo_site ledger "$SQLITE_ENV"
  cd "$PARKED/ledger"
  run vhosty worktree add x --no-install
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  W="$VHOSTY_DIR/worktrees/ledger/x"
  grep -v '^DB_DATABASE=' "$W/.env" >"$HOME/e"
  echo "DB_DATABASE=$W/database/mine.sqlite" >>"$HOME/e"
  cp "$HOME/e" "$W/.env"
  echo work >"$W/database/mine.sqlite"
  cd /
  run vhosty worktree remove x--ledger --keep-db </dev/null
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [ "$(cat "$VHOSTY_DIR/worktrees/x--ledger.sqlite")" = work ]
  # The empty file on record isn't worth a second copy
  [ ! -e "$VHOSTY_DIR/worktrees/x--ledger.2.sqlite" ]
  [ ! -e "$W" ]
}

@test "remove: --keep-db saves both when the one on record holds data too" {
  repo_site ledger "$SQLITE_ENV"
  cd "$PARKED/ledger"
  run vhosty worktree add x --no-install
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  W="$VHOSTY_DIR/worktrees/ledger/x"
  echo earlier >"$W/database/database.sqlite"
  grep -v '^DB_DATABASE=' "$W/.env" >"$HOME/e"
  echo "DB_DATABASE=database/mine.sqlite" >>"$HOME/e"
  cp "$HOME/e" "$W/.env"
  echo work >"$W/database/mine.sqlite"
  cd /
  run vhosty worktree remove x--ledger --keep-db </dev/null
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [ "$(cat "$VHOSTY_DIR/worktrees/x--ledger.sqlite")" = work ]
  [ "$(cat "$VHOSTY_DIR/worktrees/x--ledger.2.sqlite")" = earlier ]
}

@test "link: a created worktree's sqlite file isn't said to stay; an adopted one's is [A10b]" {
  repo_site ledger "$SQLITE_ENV"
  cd "$PARKED/ledger"
  run vhosty worktree add x --no-install
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  W="$VHOSTY_DIR/worktrees/ledger/x"
  sed -i.bak "s/^SITE_WT_DB_KIND=.*/SITE_WT_DB_KIND=''/; s/^SITE_WT_DB_NAME=.*/SITE_WT_DB_NAME=''/" "$VHOSTY_DIR/sites/x--ledger.conf"
  echo work >"$W/database/database.sqlite"
  run vhosty worktree link "$W" --no-install
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  refute_contains "$output" "remove leaves it"
  assert_contains "$output" "goes with the folder"
  cd /
  run vhosty worktree remove x--ledger </dev/null
  [ "$status" -ne 0 ]
  assert_contains "$output" "database/database.sqlite"
  [ "$(cat "$W/database/database.sqlite")" = work ]
  # Adopted, it does stay
  git -C "$PARKED/ledger" worktree add -q -b y "$HOME/wty"
  echo mine >"$HOME/wty/database/database.sqlite"
  cd "$HOME/wty"
  run vhosty worktree link --no-install
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  assert_contains "$output" "so remove leaves it"
}

# ---------------------------------------------------------------- small ones

@test "add: a tracked symlink where the temp file used to go can't be written through [A9]" {
  services_on
  repo_site ledger "$MYSQL_ENV"
  mysql_db ledger
  cd "$PARKED/ledger"
  cp .env "$HOME/parent.before"
  ln -s "$PARKED/ledger/.env" .env.vhosty-tmp
  git add -f .env.vhosty-tmp
  git commit -qm link
  rm .env.vhosty-tmp
  run vhosty worktree add x --no-install
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  cmp "$HOME/parent.before" "$PARKED/ledger/.env"
  assert_contains "$(cat "$VHOSTY_DIR/worktrees/ledger/x/.env")" "DB_DATABASE=wt_x__ledger"
}

@test "remove: a detached HEAD with commits only it has: warned, asked, and --yes still prints it [A16]" {
  repo_site ledger "$SQLITE_ENV"
  cd "$PARKED/ledger"
  run vhosty worktree add s --no-install --share-db
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  W="$VHOSTY_DIR/worktrees/ledger/s"
  git -C "$W" checkout -q --detach
  echo w >"$W/work.txt"
  git -C "$W" add work.txt
  git -C "$W" commit -qm precious
  cd /
  run vhosty worktree remove s--ledger </dev/null
  [ "$status" -ne 0 ]
  assert_contains "$output" "no branch or tag contains"
  [ -d "$W" ]
  run vhosty worktree remove s--ledger --yes </dev/null
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  assert_contains "$output" "no branch or tag contains"
}

@test "remove: a detached HEAD on a commit a branch has says nothing" {
  repo_site ledger "$SQLITE_ENV"
  cd "$PARKED/ledger"
  run vhosty worktree add s --no-install --share-db
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  W="$VHOSTY_DIR/worktrees/ledger/s"
  git -C "$W" checkout -q --detach
  cd /
  run vhosty worktree remove s--ledger </dev/null
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  refute_contains "$output" "no branch or tag contains"
}

@test "an unreadable parent .env is a proper message, at add and link [B11]" {
  services_on
  repo_site ledger "$MYSQL_ENV"
  mysql_db ledger
  cd "$PARKED/ledger"
  chmod 000 .env
  run vhosty worktree add x --no-install
  [ "$status" -eq 1 ]
  assert_contains "$output" "Can't read $PARKED/ledger/.env"
  refute_contains "$output" "awk"
  [ "$(git worktree list | wc -l | tr -d ' ')" = 1 ]
  git -C "$PARKED/ledger" worktree add -q -b y "$HOME/wty"
  run vhosty worktree link "$HOME/wty" --no-install
  chmod 644 .env
  [ "$status" -eq 1 ]
  assert_contains "$output" "Can't read"
  refute_contains "$output" "awk"
}

@test "guard: a linked site outside the parked folders counts too" {
  with_mysql_worktree
  mkdir -p "$HOME/elsewhere"
  printf 'DB_DATABASE=wt_feature_x__ledger\n' >"$HOME/elsewhere/.env"
  site_conf other "SITE_PATH=$HOME/elsewhere
SITE_LINKED=yes"
  not_dropped "$HOME/elsewhere/.env still names it"
}

@test "link again with no record, and a .env linked back to the parent's: replaced, and the parent's stays [B7]" {
  services_on
  repo_site ledger "$MYSQL_ENV"
  mysql_db ledger
  cp "$PARKED/ledger/.env" "$HOME/parent.before"
  git -C "$PARKED/ledger" worktree add -q -b a "$HOME/a"
  cd "$HOME/a"
  run vhosty worktree link --no-install
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  sed -i.bak "s/^SITE_WT_DB_KIND=.*/SITE_WT_DB_KIND=''/; s/^SITE_WT_DB_NAME=.*/SITE_WT_DB_NAME=''/" "$VHOSTY_DIR/sites/a--ledger.conf"
  rm -f "$HOME/db/mysql/wt_a__ledger" .env
  ln -s "$PARKED/ledger/.env" .env
  run vhosty worktree link "$HOME/a" --no-install
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [ ! -L .env ]
  assert_contains "$(cat .env)" "DB_DATABASE=wt_a__ledger"
  cmp "$HOME/parent.before" "$PARKED/ledger/.env"
}

@test "add: a branch's own .env isn't called the parent's database" {
  services_on
  repo_site ledger "$MYSQL_ENV"
  mysql_db ledger
  branch_with_env remote-cfg 'DB_CONNECTION=mysql
DB_HOST=prod.example.com
DB_DATABASE=ledger_prod'
  run vhosty worktree add remote-cfg --no-install
  [ "$status" -eq 1 ]
  assert_contains "$output" "own .env uses a database vhosty doesn't manage"
  refute_contains "$output" "share ledger's database"
}

@test "remove: git failing with nothing changed doesn't blame uncommitted files" {
  sqlite_precious
  real="$(command -v git)"
  stub git "case \"\$*\" in *'worktree remove'*) echo 'error: failed to delete: Permission denied' >&2; exit 1 ;; esac; exec \"$real\" \"\$@\""
  run vhosty worktree remove x--ledger --yes
  [ "$status" -ne 0 ]
  refute_contains "$output" "uncommitted"
  assert_contains "$output" "Permission denied"
  assert_contains "$output" "Nothing was removed"
  [ "$(cat "$W/database/database.sqlite")" = precious ]
}

# ---------------------------------------------------------------- whose database is it?

own_env_worktree() { # own_env_worktree SITE .ENV_TEXT
  git -C "$PARKED/$1" worktree add -q "$HOME/wt" -b x
  printf '%s\n' "$2" >"$HOME/wt/.env"
}

@test "link: a parent with no DB_DATABASE could be using any name, so that stops" {
  services_on
  repo_site ledger 'DB_CONNECTION=mysql
DB_HOST=127.0.0.1
DB_PORT=3306'
  mysql_db laravel
  own_env_worktree ledger 'DB_CONNECTION=mysql
DB_HOST=127.0.0.1
DB_PORT=3306
DB_DATABASE=laravel'
  run vhosty worktree link "$HOME/wt"
  [ "$status" -eq 1 ]
  assert_contains "$output" "can't tell"
  [ ! -f "$VHOSTY_DIR/sites/x--ledger.conf" ]
}

@test "link: a sqlite parent with no DB_DATABASE can't be using that server database" {
  services_on
  repo_site ledger 'DB_CONNECTION=sqlite'
  mysql_db mine
  own_env_worktree ledger 'DB_CONNECTION=mysql
DB_HOST=127.0.0.1
DB_PORT=3306
DB_DATABASE=mine'
  run vhosty worktree link "$HOME/wt"
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
}

@test "link: a worktree .env naming another site's database stops, unless --share-db" {
  services_on
  repo_site ledger "$MYSQL_ENV"
  mysql_db ledger
  mysql_db otherdb
  mkdir -p "$PARKED/other"
  echo 'DB_DATABASE=otherdb' >"$PARKED/other/.env"
  own_env_worktree ledger "${MYSQL_ENV/DB_DATABASE=ledger/DB_DATABASE=otherdb}"
  run vhosty worktree link "$HOME/wt"
  [ "$status" -eq 1 ]
  assert_contains "$output" "$PARKED/other/.env still names it"
  assert_contains "$output" "--share-db"
  run vhosty worktree link "$HOME/wt" --share-db
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [ -f "$HOME/db/mysql/otherdb" ]
}

@test "link: a worktree .env naming another folder's sqlite file stops" {
  repo_site ledger 'DB_CONNECTION=sqlite'
  mkdir -p "$PARKED/other/database"
  echo keep >"$PARKED/other/database/database.sqlite"
  echo 'DB_CONNECTION=sqlite' >"$PARKED/other/.env"
  own_env_worktree ledger "DB_CONNECTION=sqlite
DB_DATABASE=$PARKED/other/database/database.sqlite"
  run vhosty worktree link "$HOME/wt"
  [ "$status" -eq 1 ]
  assert_contains "$output" "$PARKED/other"
  [ "$(cat "$PARKED/other/database/database.sqlite")" = keep ]
}

@test "remove: a read that fails partway doesn't count as nobody using it" {
  [ -e /proc/self/mem ] || skip "needs /proc"
  services_on
  repo_site ledger "$MYSQL_ENV"
  mysql_db ledger
  cd "$PARKED/ledger"
  run vhosty worktree add f --no-install
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  mkdir -p "$PARKED/aaa" "$PARKED/zzz"
  ln -s /proc/self/mem "$PARKED/aaa/.env.x"
  echo 'DB_DATABASE=wt_f__ledger' >"$PARKED/zzz/.env"
  run vhosty worktree remove f--ledger --yes
  [ "$status" -ne 0 ]
  assert_contains "$output" "Not dropping"
  [ -f "$HOME/db/mysql/wt_f__ledger" ]
}

@test "remove: a longer database name isn't this one" {
  services_on
  repo_site ledger "$MYSQL_ENV"
  mysql_db ledger
  cd "$PARKED/ledger"
  run vhosty worktree add f --no-install
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  mkdir -p "$PARKED/other"
  echo 'DB_DATABASE=wt_f__ledger2' >"$PARKED/other/.env"
  run vhosty worktree remove f--ledger --yes
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [ ! -e "$HOME/db/mysql/wt_f__ledger" ]
}

@test "remove: names in any .env* count, and a database dropped by hand needs no guarding" {
  services_on
  repo_site ledger "$MYSQL_ENV"
  mysql_db ledger
  cd "$PARKED/ledger"
  run vhosty worktree add f --no-install
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  mkdir -p "$PARKED/other"
  echo 'DB_DATABASE=wt_f__ledger' >"$PARKED/other/.env-old"
  run vhosty worktree remove f--ledger --yes
  [ "$status" -ne 0 ]
  assert_contains "$output" "$PARKED/other/.env-old still names it"
  [ -f "$HOME/db/mysql/wt_f__ledger" ]
  rm "$HOME/db/mysql/wt_f__ledger"
  run vhosty worktree remove f--ledger --yes
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  assert_contains "$output" "already gone"
}

@test "add: a database left by --keep-db says how to drop it" {
  services_on
  repo_site ledger "$MYSQL_ENV"
  mysql_db ledger
  mysql_db wt_f__ledger
  cd "$PARKED/ledger"
  run vhosty worktree add f --no-install
  [ "$status" -eq 1 ]
  assert_contains "$output" "DROP DATABASE"
  assert_contains "$output" "wt_f__ledger"
}

@test "warns about a shared test database and a shared search index" {
  services_on
  repo_site ledger "$MYSQL_ENV
SCOUT_DRIVER=meilisearch"
  mysql_db ledger
  git -C "$PARKED/ledger" worktree add -q "$HOME/wt" -b x
  printf 'DB_CONNECTION=mysql\nDB_DATABASE=ledger_test\n' >"$HOME/wt/.env.testing"
  run vhosty worktree link "$HOME/wt" --no-install
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  assert_contains "$output" ".env.testing names the database ledger_test"
  assert_contains "$output" "SCOUT_DRIVER (meilisearch)"
}

@test "no warning for a sqlite test database, which is the worktree's own file" {
  services_on
  repo_site ledger "$MYSQL_ENV"
  mysql_db ledger
  git -C "$PARKED/ledger" worktree add -q "$HOME/wt" -b x
  printf 'DB_CONNECTION=sqlite\nDB_DATABASE=database/testing.sqlite\n' >"$HOME/wt/.env.testing"
  run vhosty worktree link "$HOME/wt" --no-install
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  refute_contains "$output" ".env.testing"
}
