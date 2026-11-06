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
  export REAL_DOCKER WT_SVC_DIR WT_MY_PORT WT_PG_PORT WT_MY2_PORT
  REAL_DOCKER="$(command -v docker)"
  # Tests point HOME elsewhere; docker's own config (compose's plugin) stays
  export DOCKER_CONFIG="${DOCKER_CONFIG:-$HOME/.docker}"
  WT_SVC_DIR="$(cd "$BATS_FILE_TMPDIR" && pwd -P)/vhostywtdb$$"
  WT_MY_PORT=$((20000 + $$ % 20000))
  WT_PG_PORT=$((WT_MY_PORT + 1))
  WT_MY2_PORT=$((WT_MY_PORT + 2))
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
  mysql2:
    image: $MYSQL_IMAGE
    environment:
      MYSQL_ROOT_PASSWORD: rootpw
    command: --lower-case-table-names=1
    ports: ["127.0.0.1:$WT_MY2_PORT:3306"]
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
  until my -e 'select 1' >/dev/null 2>&1 && my2 -e 'select 1' >/dev/null 2>&1 && pg -d postgres -c 'select 1' >/dev/null 2>&1; do
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

teardown() {
  [ -z "${FW:-}" ] || kill "$FW" 2>/dev/null || true
}

vhosty() { "${VHOSTY_TEST_BASH:-bash}" "$ROOT/bin/vhosty" "$@"; }
dcx() { "${REAL_DOCKER:-docker}" compose --project-directory "$WT_SVC_DIR" "$@"; }
my() { dcx exec -T mysql sh -c 'MYSQL_PWD=rootpw exec mysql -uroot -h127.0.0.1 "$@"' sh "$@" </dev/null; }
my_as() { # my_as USER PASSWORD [args]
  dcx exec -T mysql sh -c 'export MYSQL_PWD="$2"; u="$1"; shift 2; exec mysql -u"$u" -h127.0.0.1 "$@"' sh "$@" </dev/null
}
my2() { dcx exec -T mysql2 sh -c 'MYSQL_PWD=rootpw exec mysql -uroot -h127.0.0.1 "$@"' sh "$@" </dev/null; }
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

# copy_stays_home NAME: --copy-db worked, named what it left out, and a write to
# the copy reaches nothing else: the parent's log and any third database stay as they were
copy_stays_home() {
  run vhosty worktree add x --copy-db --no-install
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  assert_contains "$output" "not copied"
  assert_contains "$output" "$1"
  [ "$(my -Ne "select count(*) from $WT_DB.t")" = 1 ]
  my -e "insert into $WT_DB.t values (99)"
  [ "$(my -Ne "select count(*) from $WT_DB.t")" = 2 ]
  [ "$(my -Ne "select count(*) from $PARENT_DB.log where a = 99")" = 0 ]
  [ "$(my -Ne "select count(*) from $PARENT_DB.t where a = 99")" = 0 ]
  [ "$(my -Ne "select count(*) from information_schema.triggers where trigger_schema = '$WT_DB'")" = 0 ]
  [ "$(my -Ne "select count(*) from information_schema.routines where routine_schema = '$WT_DB'")" = 0 ]
  [ "$(my -Ne "select count(*) from information_schema.events where event_schema = '$WT_DB'")" = 0 ]
}

@test "real mysql: trigger, routine and event are left out, and named" {
  mysql_site
  my "$PARENT_DB" -e "create trigger audit after insert on t for each row insert into $PARENT_DB.log values (new.a);
    create procedure rollup_it() insert into \`$PARENT_DB\` . log values (1);
    create event nightly on schedule every 1 day starts current_timestamp + interval 1 day do insert into $PARENT_DB.log values (2);"
  copy_stays_home "trigger audit"
  assert_contains "$output" "procedure rollup_it"
  assert_contains "$output" "event nightly"
  # They're all still on the parent, where they belong
  [ "$(my -Ne "select count(*) from information_schema.triggers where trigger_schema = '$PARENT_DB'")" = 1 ]
  my "$PARENT_DB" -e "insert into t values (5)"
  [ "$(my -Ne "select count(*) from $PARENT_DB.log where a = 5")" = 1 ]
}

@test "real mysql: a trigger written with ANSI quotes can't reach the parent from the copy [M1]" {
  mysql_site
  my -e "set sql_mode='ANSI_QUOTES'; use $PARENT_DB; create trigger tq after insert on t for each row insert into \"$PARENT_DB\".log values (new.a);"
  copy_stays_home "trigger tq"
}

@test "real mysql: a comment between name and dot can't either [M2]" {
  mysql_site
  my -e "use $PARENT_DB; create trigger tq after insert on t for each row insert into $PARENT_DB/**/.log values (new.a);"
  copy_stays_home "trigger tq"
}

@test "real mysql: backticks and spaces can't either [M3]" {
  mysql_site
  my -e "use $PARENT_DB; create trigger tq after insert on t for each row insert into \`$PARENT_DB\`  .  \`log\` values (new.a);"
  copy_stays_home "trigger tq"
}

@test "real mysql: a routine in a third database that writes to the parent can't either [M4]" {
  mysql_site
  my -e "create database u$N; create procedure u$N.w(x int) insert into $PARENT_DB.log values (x);"
  my -e "use $PARENT_DB; create trigger tq after insert on t for each row call u$N.w(new.a);"
  copy_stays_home "trigger tq"
}

@test "real mysql: a trigger that writes to a third database can't either [M5]" {
  mysql_site
  my -e "create database a$N; create table a$N.log (a int); use $PARENT_DB; create trigger tq after insert on t for each row insert into a$N.log values (new.a);"
  copy_stays_home "trigger tq"
  [ "$(my -Ne "select count(*) from a$N.log where a = 99")" = 0 ]
}

@test "real mysql: a prepared statement in a routine isn't there to call [M6]" {
  mysql_site
  dcx exec -T mysql sh -c 'MYSQL_PWD=rootpw exec mysql -uroot -h127.0.0.1' <<SQL
use $PARENT_DB;
delimiter //
create procedure pr() begin set @s=concat('insert into ','$PARENT_DB','.log values (99)'); prepare st from @s; execute st; deallocate prepare st; end//
delimiter ;
SQL
  copy_stays_home "procedure pr"
  refute my -e "use $WT_DB; call pr()"
  [ "$(my -Ne "select count(*) from $PARENT_DB.log where a = 99")" = 0 ]
}

@test "real mysql: a view on the parent's own table comes over as the copy's own [M7]" {
  mysql_site
  my -e "use $PARENT_DB; create view v as select a from $PARENT_DB.log;"
  run vhosty worktree add x --copy-db --no-install
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  my -e "insert into $WT_DB.v values (99)"
  [ "$(my -Ne "select count(*) from $PARENT_DB.log where a = 99")" = 0 ]
  [ "$(my -Ne "select count(*) from $WT_DB.log where a = 99")" = 1 ]
}

@test "real mysql: views come over and act on the copy; triggers and routines stay behind" {
  mysql_site
  my "$PARENT_DB" -e "create trigger audit after insert on t for each row insert into log values (new.a);
    create view v as select a from $PARENT_DB.t;
    create procedure not_me() insert into log values (9);"
  run vhosty worktree add x --copy-db
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  assert_contains "$output" "trigger audit"
  assert_contains "$output" "procedure not_me"
  my "$WT_DB" -e 'insert into t values (2)'
  [ "$(my -Ne "select count(*) from $WT_DB.log")" = 0 ]
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

# ---------------------------------------------------------------- reach

@test "real postgres: a dblink parent isn't copied: empty, exit 1, says why [PG1]" {
  pg_site
  pg -d "$PARENT_DB" -c "create extension dblink; create table t (a int primary key); create table log (a int); alter table t owner to $APP; alter table log owner to $APP; insert into t values (1);"
  pg -d "$PARENT_DB" -c "create function f() returns trigger language plpgsql as \$x\$ begin perform dblink_exec('host=postgres dbname=$PARENT_DB user=$APP password=apppw','insert into log values ('||new.a||')'); return new; end \$x\$; alter function f() owner to $APP; create trigger tr after insert on t for each row execute function f();"
  run vhosty worktree add x --copy-db --no-install
  [ "$status" -eq 1 ]
  assert_contains "$output" "not copying $PARENT_DB"
  assert_contains "$output" "extension dblink"
  assert_contains "$output" "stays empty"
  [ "$(pg -d "$WT_DB" -Atc "select count(*) from information_schema.tables where table_schema = 'public'")" = 0 ]
  [ "$(pg -d "$PARENT_DB" -Atc 'select count(*) from log')" = 0 ]
  [ "$(. "$VHOSTY_DIR/sites/$WT_NAME.conf"; printf %s "$SITE_WT_DB_NAME")" = "$WT_DB" ]
}

@test "real postgres: a postgres_fdw foreign table isn't copied [PG2]" {
  pg_site
  pg -d "$PARENT_DB" -c "create extension postgres_fdw; create table log (a int); create server s foreign data wrapper postgres_fdw options (host '127.0.0.1', dbname '$PARENT_DB'); create user mapping for public server s options (user 'super', password 'pgpw'); create foreign table ft (a int) server s options (table_name 'log');"
  run vhosty worktree add x --copy-db --no-install
  [ "$status" -eq 1 ]
  assert_contains "$output" "extension postgres_fdw"
  assert_contains "$output" "foreign table ft"
  [ "$(pg -d "$WT_DB" -Atc "select count(*) from information_schema.tables where table_schema = 'public'")" = 0 ]
  cd /
  run vhosty worktree remove "$WT_NAME" --yes
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
}

@test "real postgres: an ordinary parent is still copied, data and all" {
  pg_site
  pg -d "$PARENT_DB" -c "create table t (a int primary key); alter table t owner to $APP; insert into t values (1);"
  run vhosty worktree add x --copy-db --no-install
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [ "$(pg -d "$WT_DB" -Atc 'select count(*) from t')" = 1 ]
}

# ---------------------------------------------------------------- managed

# tunnel HOST PORT TARGET: something other than the service, listening there
tunnel() {
  command -v python3 >/dev/null 2>&1 || skip "needs python3"
  cat >"$HOME/forward.py" <<'PY'
import socket,sys,threading
lhost,lport,tport=sys.argv[1],int(sys.argv[2]),int(sys.argv[3])
s=socket.socket(socket.AF_INET); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1); s.bind((lhost,lport)); s.listen(16)
def pump(a,b):
    try:
        while True:
            d=a.recv(65536)
            if not d: break
            b.sendall(d)
    except OSError: pass
    try: b.shutdown(socket.SHUT_WR)
    except OSError: pass
while True:
    c,_=s.accept(); u=socket.create_connection(('127.0.0.1',tport))
    threading.Thread(target=pump,args=(c,u),daemon=True).start(); threading.Thread(target=pump,args=(u,c),daemon=True).start()
PY
  python3 "$HOME/forward.py" "$1" "$2" "$3" >/dev/null 2>&1 3>&- &
  FW=$!
  sleep 0.5
}

@test "real: DB_HOST=::1 isn't a service, whatever's listening there [T1]" {
  site_repo "DB_CONNECTION=mysql
DB_HOST=::1
DB_PORT=$WT_MY_PORT
DB_DATABASE=$PARENT_DB
DB_USERNAME=root
DB_PASSWORD=rootpw"
  cd "$PARKED/$SITE"
  run vhosty worktree add x --no-install
  [ "$status" -eq 1 ]
  assert_contains "$output" "would share"
  [ ! -e "$WT" ]
  [ "$(my -Ne "select count(*) from information_schema.schemata where schema_name = '$WT_DB'")" = 0 ]
}

@test "real: a tunnel on 127.0.0.1, compose.yaml edited and not applied, isn't the service [T2, T3]" {
  port=$((WT_MY_PORT + 7))
  my2 -e "create database $PARENT_DB"
  tunnel 127.0.0.1 "$port" "$WT_MY2_PORT"
  site_repo "DB_CONNECTION=mysql
DB_HOST=127.0.0.1
DB_PORT=$port
DB_DATABASE=$PARENT_DB
DB_USERNAME=root
DB_PASSWORD=rootpw"
  cd "$PARKED/$SITE"
  run vhosty worktree add x --no-install
  [ "$status" -eq 1 ]
  assert_contains "$output" "no vhosty docker service publishes mysql on port $port"
  cp "$WT_SVC_DIR/compose.yaml" "$HOME/compose.keep"
  sed "s/127.0.0.1:$WT_MY_PORT:3306/127.0.0.1:$port:3306/" "$HOME/compose.keep" >"$WT_SVC_DIR/compose.yaml"
  run vhosty worktree add x --no-install
  cp "$HOME/compose.keep" "$WT_SVC_DIR/compose.yaml"
  [ "$status" -eq 1 ]
  assert_contains "$output" "no running container does"
  [ ! -e "$WT" ]
  [ "$(my2 -Ne "select count(*) from information_schema.schemata where schema_name = '$WT_DB'")" = 0 ]
  [ "$(my -Ne "select count(*) from information_schema.schemata where schema_name = '$WT_DB'")" = 0 ]
}

@test "real: a stopped service stops it, and says to start it" {
  site_repo "DB_CONNECTION=mysql
DB_HOST=127.0.0.1
DB_PORT=$WT_MY2_PORT
DB_DATABASE=$PARENT_DB
DB_USERNAME=root
DB_PASSWORD=rootpw"
  cd "$PARKED/$SITE"
  dcx stop mysql2 >/dev/null 2>&1
  run vhosty worktree add x --no-install
  dcx start mysql2 >/dev/null 2>&1
  i=0
  until my2 -e 'select 1' >/dev/null 2>&1; do i=$((i + 1)); [ "$i" -lt 120 ] || false; sleep 1; done
  [ "$status" -eq 1 ]
  assert_contains "$output" "vhosty services up mysql2"
  [ ! -e "$WT" ]
}

# ---------------------------------------------------------------- lower_case_table_names

@test "real mysql: capitals reach the same database on a case-folding server: a sibling's stop the drop [L1]" {
  site_repo "DB_CONNECTION=mysql
DB_HOST=127.0.0.1
DB_PORT=$WT_MY2_PORT
DB_DATABASE=$PARENT_DB
DB_USERNAME=root
DB_PASSWORD=rootpw"
  my2 -e "create database $PARENT_DB"
  cd "$PARKED/$SITE"
  run vhosty worktree add x --no-install
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  my2 -e "create table $WT_DB.t (a int); insert into $WT_DB.t values (1)"
  U="$(printf '%s' "$WT_DB" | tr a-z A-Z)"
  [ "$(my2 -N -D "$U" -e 'select count(*) from t')" = 1 ]
  mkdir -p "$PARKED/other"
  echo "DB_DATABASE=$U" >"$PARKED/other/.env"
  cd /
  run vhosty worktree remove "$WT_NAME" --yes
  [ "$status" -ne 0 ]
  assert_contains "$output" "$PARKED/other/.env still names it"
  [ "$(my2 -Ne "select count(*) from $WT_DB.t")" = 1 ]
}

@test "real mysql: a worktree's own .env naming the parent in capitals gets its own [L2]" {
  site_repo "DB_CONNECTION=mysql
DB_HOST=127.0.0.1
DB_PORT=$WT_MY2_PORT
DB_DATABASE=$PARENT_DB
DB_USERNAME=root
DB_PASSWORD=rootpw"
  my2 -e "create database $PARENT_DB"
  U="$(printf '%s' "$PARENT_DB" | tr a-z A-Z)"
  git -C "$PARKED/$SITE" worktree add -q -b x "$HOME/w"
  sed "s/^DB_DATABASE=.*/DB_DATABASE=$U/" "$PARKED/$SITE/.env" >"$HOME/w/.env"
  cd "$HOME/w"
  run vhosty worktree link --no-install
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  assert_contains "$(cat .env)" "DB_DATABASE=$WT_DB"
  [ "$(my2 -Ne "select count(*) from information_schema.schemata where schema_name = '$WT_DB'")" = 1 ]
}

# ---------------------------------------------------------------- backups

@test "real: backups skip what's on record, and only that [BK]" {
  site_repo "DB_CONNECTION=mysql
DB_HOST=127.0.0.1
DB_PORT=$WT_MY_PORT
DB_DATABASE=wt_ledger$N
DB_USERNAME=root
DB_PASSWORD=rootpw"
  my -e "create database wt_ledger$N; create table wt_ledger$N.a (a int); insert into wt_ledger$N.a values (1);
    create database wt_payroll$N; create table wt_payroll$N.p (a int); insert into wt_payroll$N.p values (1);"
  cd "$PARKED/$SITE"
  run vhosty worktree add x --no-install
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  run vhosty worktree add kept --no-install
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  run vhosty worktree remove "kept--$SITE" --keep-db
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  run vhosty services backup --to "$HOME/bk"
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  assert_contains "$output" "$WT_DB"
  d="$(ls -d "$HOME"/bk/services-*)"
  [ -f "$d/mysql/wt_ledger$N.sql.gz" ]
  [ -f "$d/mysql/wt_payroll$N.sql.gz" ]
  [ -f "$d/mysql/wt_kept__$SITE.sql.gz" ]
  [ ! -e "$d/mysql/$WT_DB.sql.gz" ]
}
