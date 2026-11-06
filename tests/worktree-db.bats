#!/usr/bin/env bats
# vhosty worktree against real MySQL and Postgres servers. Skips without docker,
# or without these images: it never pulls one. Its containers are its own (a
# compose project with a unique name, high ports, tmpfs, no volumes), and they
# go when the file's done. Nothing here reaches any other container.

load helpers

MYSQL_IMAGE="mysql:8.4"
PG_IMAGE="pgvector/pgvector:pg18-trixie"

setup_file() {
  export WT_DB_SKIP=""
  if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    WT_DB_SKIP="no docker here"; return 0
  fi
  if ! docker compose version >/dev/null 2>&1; then
    WT_DB_SKIP="no docker compose here"; return 0
  fi
  if ! docker image inspect "$MYSQL_IMAGE" "$PG_IMAGE" >/dev/null 2>&1; then
    WT_DB_SKIP="needs the images $MYSQL_IMAGE and $PG_IMAGE, and won't pull them"; return 0
  fi
  export REAL_DOCKER WT_SVC_DIR WT_MY_PORT WT_PG_PORT
  REAL_DOCKER="$(command -v docker)"
  # Tests point HOME elsewhere; docker's own config (compose's plugin) stays
  export DOCKER_CONFIG="${DOCKER_CONFIG:-$HOME/.docker}"
  WT_SVC_DIR="$(cd "$BATS_FILE_TMPDIR" && pwd -P)/vhostywtdb$$"
  WT_MY_PORT=$((20000 + $$ % 20000))
  WT_PG_PORT=$((WT_MY_PORT + 1))
  mkdir -p "$WT_SVC_DIR"
  cat >"$WT_SVC_DIR/compose.yaml" <<YAML
services:
  mysql:
    image: $MYSQL_IMAGE
    environment:
      MYSQL_ROOT_PASSWORD: rootpw
    command: --gtid-mode=ON --enforce-gtid-consistency=ON --general-log=1 --log-output=TABLE
    ports: ["127.0.0.1:$WT_MY_PORT:3306"]
    tmpfs: [/var/lib/mysql]
  postgres:
    image: $PG_IMAGE
    environment:
      POSTGRES_USER: super
      POSTGRES_PASSWORD: pgpw
    ports: ["127.0.0.1:$WT_PG_PORT:5432"]
    tmpfs: [/var/lib/postgresql]
YAML
  dcx up -d --pull never --quiet-pull >/dev/null 2>&1 || { dcx down -v --remove-orphans >/dev/null 2>&1; return 1; }
  local i=0
  until my -e 'select 1' >/dev/null 2>&1 && pg -d postgres -c 'select 1' >/dev/null 2>&1; do
    i=$((i + 1))
    if [ "$i" -gt 180 ]; then dcx logs >&2; dcx down -v --remove-orphans >/dev/null 2>&1; return 1; fi
    sleep 1
  done
}

teardown_file() {
  [ -z "${WT_SVC_DIR:-}" ] || dcx down -v --remove-orphans >/dev/null 2>&1 || true
}

setup() {
  [ -z "${WT_DB_SKIP:-}" ] || skip "$WT_DB_SKIP"
  BATS_TEST_TMPDIR="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  vhosty_setup
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
  export GIT_CONFIG_NOSYSTEM=1
  git config --global init.defaultBranch main
  git config --global advice.detachedHead false
  stub systemctl 'exit 1'
  stub launchctl 'exit 1'
  stub sudo 'exit 1'
  stub composer 'exit 0'
  # Real docker, except that nothing gets pulled
  stub docker 'case "$1 ${2:-}" in pull*|"compose pull"*) echo "docker pull refused in tests" >&2; exit 0 ;; esac; exec "$REAL_DOCKER" "$@"'
  write_config "VHOSTY_SERVICES_DIR=\"$WT_SVC_DIR\""
  # Names of its own in the shared servers
  N="$BATS_TEST_NUMBER"
  SITE="s$N"; PARENT_DB="p$N"; APP="app$N"; WT_NAME="x--$SITE"; WT_DB="wt_x__$SITE"
  WT="$VHOSTY_DIR/worktrees/$SITE/x"
}

vhosty() { "${VHOSTY_TEST_BASH:-bash}" "$ROOT/bin/vhosty" "$@"; }
dcx() { "${REAL_DOCKER:-docker}" compose --project-directory "$WT_SVC_DIR" "$@"; }
my() { dcx exec -T mysql sh -c 'MYSQL_PWD=rootpw exec mysql -uroot -h127.0.0.1 "$@"' sh "$@" </dev/null; }
my_as() { # my_as USER PASSWORD [args]
  dcx exec -T mysql sh -c 'export MYSQL_PWD="$2"; u="$1"; shift 2; exec mysql -u"$u" -h127.0.0.1 "$@"' sh "$@" </dev/null
}
pg() { dcx exec -T postgres sh -c 'PGPASSWORD=pgpw exec psql -U super -h127.0.0.1 -v ON_ERROR_STOP=1 -q "$@"' sh "$@" </dev/null; }
pg_as() { # pg_as ROLE PASSWORD [args]
  dcx exec -T postgres sh -c 'PGPASSWORD="$2" u="$1"; export PGPASSWORD; shift 2; exec psql -U "$u" -h127.0.0.1 -v ON_ERROR_STOP=1 -q "$@"' sh "$@" </dev/null
}

site_repo() { # site_repo [.env text]
  local d="$PARKED/$SITE"
  mkdir -p "$d/public" "$d/database"
  echo '<?php' >"$d/public/index.php"
  printf '.env\n*.sqlite\n/vendor\n' >"$d/.gitignore"
  echo keep >"$d/database/.gitkeep"
  [ $# -lt 1 ] || printf '%s\n' "$1" >"$d/.env"
  git -C "$d" init -q
  git -C "$d" add -A
  git -C "$d" commit -qm first
}

mysql_site() { # the parent on root, or the user given
  site_repo "DB_CONNECTION=mysql
DB_HOST=127.0.0.1
DB_PORT=$WT_MY_PORT
DB_DATABASE=$PARENT_DB
DB_USERNAME=${1:-root}
DB_PASSWORD=rootpw"
  my -e "create database $PARENT_DB; use $PARENT_DB; create table t (a int primary key); create table log (a int); insert into t values (1);"
  cd "$PARKED/$SITE"
}

pg_site() { # the parent on a role that isn't a superuser, with these extensions
  site_repo "DB_CONNECTION=pgsql
DB_HOST=127.0.0.1
DB_PORT=$WT_PG_PORT
DB_DATABASE=$PARENT_DB
DB_USERNAME=$APP
DB_PASSWORD=apppw"
  pg -d postgres -c "create role $APP login password 'apppw' nosuperuser"
  pg -d postgres -c "create database $PARENT_DB owner $APP"
  cd "$PARKED/$SITE"
}

# ---------------------------------------------------------------- MySQL

@test "real mysql: a new database, with access for the app's own user" {
  my -e "create user '$APP'@'%' identified by 'apppw'"
  mysql_site "$APP"
  run vhosty worktree add x
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  my_as "$APP" apppw "$WT_DB" -e 'create table mine (a int); insert into mine values (1)'
  [ "$(my_as "$APP" apppw "$WT_DB" -Ne 'select count(*) from mine')" = 1 ]
  # ...and no more than that
  refute my_as "$APP" apppw "$PARENT_DB" -Ne 'select 1 from t'
  run vhosty worktree remove "$WT_NAME" --yes
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [ "$(my -Ne "select count(*) from information_schema.schemata where schema_name = '$WT_DB'")" = 0 ]
  [ "$(my -Ne "select count(*) from $PARENT_DB.t")" = 1 ]
}

@test "real mysql (GTID): --copy-db works, and the general log shows no global lock" {
  [ "$(my -Ne 'select @@gtid_mode')" = ON ]
  mysql_site
  my -e 'truncate mysql.general_log'
  run vhosty worktree add x --copy-db
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [ "$(my -Ne "select count(*) from $WT_DB.t")" = 1 ]
  [ "$(my -Ne "select count(*) from $PARENT_DB.t")" = 1 ]
  my -Ne "set global general_log = 0"
  log="$(my -Ne "select convert(argument using utf8mb4) from mysql.general_log")"
  my -Ne "set global general_log = 1"
  # The log saw the dump, in one transaction, with no lock on the parent. The
  # WRITE locks it does show are the load's, on the copy, from the dump's text.
  assert_contains "$log" "WITH CONSISTENT SNAPSHOT"
  refute_contains "$log" "FLUSH TABLES"
  refute_contains "$log" "READ LOCK"
  refute_contains "$log" " READ /*!32311 LOCAL */"
  refute_contains "$log" "GTID_PURGED"
}

@test "real mysql: each of a trigger, routine and event naming the parent stops the copy" {
  mysql_site
  my "$PARENT_DB" -e "create trigger audit after insert on t for each row insert into $PARENT_DB.log values (new.a);
    create procedure rollup_it() insert into \`$PARENT_DB\` . log values (1);
    create event nightly on schedule every 1 day starts current_timestamp + interval 1 day do insert into $PARENT_DB.log values (2);"
  run vhosty worktree add x --copy-db
  [ "$status" -eq 1 ]
  assert_contains "$output" "not copying $PARENT_DB"
  assert_contains "$output" "trigger audit"
  assert_contains "$output" "procedure rollup_it"
  assert_contains "$output" "event nightly"
  [ "$(my -Ne "select count(*) from information_schema.tables where table_schema = '$WT_DB'")" = 0 ]
  [ "$(. "$VHOSTY_DIR/sites/$WT_NAME.conf"; printf %s "$SITE_WT_DB_NAME")" = "$WT_DB" ]
  # The check itself changes nothing on the parent's side
  [ "$(my -Ne "select count(*) from $PARENT_DB.log")" = 0 ]
}

@test "real mysql: unqualified triggers and views copy, and act on the copy" {
  mysql_site
  my "$PARENT_DB" -e "create trigger audit after insert on t for each row insert into log values (new.a);
    create view v as select a from $PARENT_DB.t;
    create procedure not_me() insert into log values (9);"
  run vhosty worktree add x --copy-db
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  my "$WT_DB" -e 'insert into t values (2)'
  [ "$(my -Ne "select count(*) from $WT_DB.log")" = 1 ]
  [ "$(my -Ne "select count(*) from $PARENT_DB.log")" = 0 ]
  [ "$(my -Ne "select count(*) from $PARENT_DB.t")" = 1 ]
  # The view is the copy's: it sees the new row, and doesn't read from the parent
  [ "$(my -Ne "select count(*) from $WT_DB.v")" = 2 ]
  refute_contains "$(my -Ne "select view_definition from information_schema.views where table_schema = '$WT_DB'")" "$PARENT_DB"
}

@test "real mysql: the printed drop hint works, and holds no password" {
  mysql_site
  run vhosty worktree add x
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  run vhosty worktree remove "$WT_NAME" --keep-db
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  refute_contains "$output" rootpw
  h="$(printf '%s\n' "$output" | sed -n 's/.*To drop it: //p')"
  [ -n "$h" ]
  [ "$(my -Ne "select count(*) from information_schema.schemata where schema_name = '$WT_DB'")" = 1 ]
  eval "$h"
  [ "$(my -Ne "select count(*) from information_schema.schemata where schema_name = '$WT_DB'")" = 0 ]
}

@test "real mysql: remove from inside the worktree drops the database" {
  mysql_site
  run vhosty worktree add x
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  cd "$WT"
  run vhosty worktree remove "$WT_NAME" --yes
  cd "$HOME"   # gone with the worktree, and compose won't run from there
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [ "$(my -Ne "select count(*) from information_schema.schemata where schema_name = '$WT_DB'")" = 0 ]
  [ ! -e "$WT" ]
}

@test "real mysql: link, remove, link makes the database again" {
  mysql_site
  git worktree add -q "$HOME/wt" -b x
  run vhosty worktree link "$HOME/wt"
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  run vhosty worktree remove "$WT_NAME" --yes
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [ "$(my -Ne "select count(*) from information_schema.schemata where schema_name = '$WT_DB'")" = 0 ]
  run vhosty worktree link "$HOME/wt"
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [ "$(my -Ne "select count(*) from information_schema.schemata where schema_name = '$WT_DB'")" = 1 ]
}

# ---------------------------------------------------------------- Postgres

@test "real postgres: an empty database has the parent's extensions, for a role that can't create them" {
  pg_site
  pg -d "$PARENT_DB" -c 'create extension vector'
  # The owner of a database can't create this one (pg_trgm it could: it's "trusted")
  pg -d postgres -c "create database q$N owner $APP"
  refute pg_as "$APP" apppw -d "q$N" -c 'create extension vector'
  run vhosty worktree add x
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  assert_contains "$output" "php artisan migrate --seed"
  # What a migration would do, as the app
  pg_as "$APP" apppw -d "$WT_DB" -c 'create table items (e vector(3))'
  [ "$(pg -d "$WT_DB" -Atc "select tableowner from pg_tables where tablename = 'items'")" = "$APP" ]
}

@test "real postgres: an extension in its own schema, empty and copied" {
  pg_site
  pg -d "$PARENT_DB" -c "create schema extensions authorization $APP; create extension pg_trgm with schema extensions; create extension vector"
  pg_as "$APP" apppw -d "$PARENT_DB" -c "create table t (a text, e vector(3)); insert into t values ('one', '[1,2,3]'); create index on t using gin (a extensions.gin_trgm_ops)"
  run vhosty worktree add x --copy-db
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [ "$(pg -d "$WT_DB" -Atc 'select a from t')" = one ]
  [ "$(pg -d "$WT_DB" -Atc "select n.nspname from pg_extension e join pg_namespace n on n.oid = e.extnamespace where e.extname = 'pg_trgm'")" = extensions ]
  [ "$(pg -d "$WT_DB" -Atc "select tableowner from pg_tables where tablename = 't'")" = "$APP" ]
  pg_as "$APP" apppw -d "$WT_DB" -c "insert into t values ('two', '[4,5,6]')"
  [ "$(pg -d "$PARENT_DB" -Atc 'select count(*) from t')" = 1 ]
  # And an empty one, from the same parent
  git -C "$PARKED/$SITE" branch y
  run vhosty worktree add y
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [ "$(pg -d "wt_y__$SITE" -Atc "select n.nspname from pg_extension e join pg_namespace n on n.oid = e.extnamespace where e.extname = 'pg_trgm'")" = extensions ]
}

@test "real postgres: the printed drop hint works with its own superuser name" {
  pg_site
  run vhosty worktree add x
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  run vhosty worktree remove "$WT_NAME" --keep-db
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  refute_contains "$output" pgpw
  refute_contains "$output" apppw
  h="$(printf '%s\n' "$output" | sed -n 's/.*To drop it: //p')"
  [ -n "$h" ]
  [ "$(pg -d postgres -Atc "select count(*) from pg_database where datname = '$WT_DB'")" = 1 ]
  eval "$h"
  [ "$(pg -d postgres -Atc "select count(*) from pg_database where datname = '$WT_DB'")" = 0 ]
}

@test "real postgres: remove from inside the worktree drops the database" {
  pg_site
  run vhosty worktree add x
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  cd "$WT"
  run vhosty worktree remove "$WT_NAME" --yes
  cd "$HOME"
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [ "$(pg -d postgres -Atc "select count(*) from pg_database where datname = '$WT_DB'")" = 0 ]
}

# ---------------------------------------------------------------- backups

@test "real services: backup skips worktree databases, and an old backup with one restores it" {
  mysql_site
  run vhosty worktree add x
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  run vhosty services backup --to "$HOME/backups"
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  assert_contains "$output" "skipped test and worktree databases"
  b="$(ls -d "$HOME"/backups/services-*)"
  grep -q "|$PARENT_DB|" "$b/MANIFEST"
  refute grep -q "|$WT_DB|" "$b/MANIFEST"
  [ ! -e "$b/mysql/$WT_DB.sql.gz" ]
  # A backup from before this skipped them
  my "$WT_DB" -e 'create table kept (a int); insert into kept values (7)'
  dcx exec -T mysql sh -c 'MYSQL_PWD=rootpw exec mysqldump -uroot -h127.0.0.1 --set-gtid-purged=OFF --databases "$1"' sh "$WT_DB" </dev/null | gzip >"$b/mysql/$WT_DB.sql.gz"
  echo "mysql|mysql|$WT_DB|mysql/$WT_DB.sql.gz" >>"$b/MANIFEST"
  # Only that one: the other services are in use by other tests here
  { grep -v '|' "$b/MANIFEST"; grep "|$WT_DB|" "$b/MANIFEST"; } >"$b/M"
  mv "$b/M" "$b/MANIFEST"
  my -e "drop database $WT_DB"
  run vhosty services restore "$b" --into "$WT_SVC_DIR" --yes
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  assert_contains "$output" "$WT_DB loaded"
  [ "$(my -Ne "select a from $WT_DB.kept")" = 7 ]
}
