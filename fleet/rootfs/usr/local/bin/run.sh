#!/usr/bin/env bash
set -euo pipefail

OPTS=/data/options.json
opt() { jq -r "$1 // empty" "$OPTS"; }
log() { echo "[fleet-app] $*"; }

SOCK=/run/mysqld/mysqld.sock
CNF=/etc/fleet-mysql.cnf
SECRETS=/data/secrets
ROOT_CNF=/run/mysqld/root.cnf

mkdir -p "$SECRETS" /data/logs /data/tmp /data/mysql /run/mysqld
chmod 700 "$SECRETS"
chown mysql:mysql /data/mysql /run/mysqld

gen_secret() {  # file, bytes
  [[ -s "$1" ]] || { openssl rand -base64 "$2" | tr -d '\n' > "$1"; chmod 600 "$1"; }
}
gen_secret "$SECRETS/mysql_root_password" 24
gen_secret "$SECRETS/mysql_fleet_password" 24
gen_secret "$SECRETS/server_private_key" 32   # Fleet: >= 32 bytes, must never change

ROOT_PW=$(<"$SECRETS/mysql_root_password")
FLEET_PW=$(<"$SECRETS/mysql_fleet_password")
BUFPOOL="$(opt .innodb_buffer_pool_mb)M"

# ---------- MySQL ----------
FIRST_RUN=0
if [[ ! -d /data/mysql/mysql ]]; then
  log "Initializing MySQL datadir"
  mysqld --defaults-file="$CNF" --initialize-insecure --user=mysql
  FIRST_RUN=1
fi

mysqld --defaults-file="$CNF" --user=mysql --innodb-buffer-pool-size="$BUFPOOL" &
MYSQL_PID=$!

for _ in $(seq 1 90); do
  # ping exits 0 once the server answers, even if auth is refused
  mysqladmin --socket="$SOCK" ping --silent >/dev/null 2>&1 && break
  kill -0 "$MYSQL_PID" 2>/dev/null || { log "mysqld exited during startup"; exit 1; }
  sleep 1
done

if (( FIRST_RUN )); then
  mysql --socket="$SOCK" -uroot --skip-password \
    -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${ROOT_PW}';"
fi

umask 077
printf '[client]\nuser=root\npassword=%s\nsocket=%s\n' "$ROOT_PW" "$SOCK" > "$ROOT_CNF"
umask 022

mysql --defaults-extra-file="$ROOT_CNF" <<SQL
CREATE DATABASE IF NOT EXISTS fleet;
CREATE USER IF NOT EXISTS 'fleet'@'127.0.0.1' IDENTIFIED BY '${FLEET_PW}';
ALTER USER 'fleet'@'127.0.0.1' IDENTIFIED BY '${FLEET_PW}';
GRANT ALL PRIVILEGES ON fleet.* TO 'fleet'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL

# ---------- Redis (cache/queue only; no persistence needed) ----------
redis-server --bind 127.0.0.1 --port 6379 --save '' --appendonly no \
             --protected-mode yes --daemonize no &
REDIS_PID=$!
for _ in $(seq 1 30); do redis-cli -h 127.0.0.1 ping >/dev/null 2>&1 && break; sleep 1; done

# ---------- Fleet ----------
export FLEET_MYSQL_ADDRESS=127.0.0.1:3306
export FLEET_MYSQL_DATABASE=fleet
export FLEET_MYSQL_USERNAME=fleet
export FLEET_MYSQL_PASSWORD="$FLEET_PW"
export FLEET_REDIS_ADDRESS=127.0.0.1:6379
export FLEET_SERVER_ADDRESS=0.0.0.0:1337
export FLEET_SERVER_PRIVATE_KEY="$(<"$SECRETS/server_private_key")"
export FLEET_FILESYSTEM_STATUS_LOG_FILE=/data/logs/osqueryd.status.log
export FLEET_FILESYSTEM_RESULT_LOG_FILE=/data/logs/osqueryd.results.log
export FLEET_FILESYSTEM_AUDIT_LOG_FILE=/data/logs/fleet.audit.log
export FLEET_FILESYSTEM_ENABLE_LOG_ROTATION=true
export FLEET_FILESYSTEM_ENABLE_LOG_COMPRESSION=true
export FLEET_LOGGING_DEBUG="$(opt .debug)"
# Without S3 configured, Fleet keeps uploaded installers/bootstrap packages under
# os.TempDir(); point it at persistent storage.
export TMPDIR=/data/tmp

if [[ "$(opt .ssl)" == "true" ]]; then
  export FLEET_SERVER_TLS=true
  export FLEET_SERVER_CERT="/ssl/$(opt .certfile)"
  export FLEET_SERVER_KEY="/ssl/$(opt .keyfile)"
  [[ -r "$FLEET_SERVER_CERT" && -r "$FLEET_SERVER_KEY" ]] \
    || { log "TLS enabled but $FLEET_SERVER_CERT / $FLEET_SERVER_KEY not readable"; exit 1; }
else
  log "TLS disabled: terminate TLS at a reverse proxy; osquery/fleetd will not enroll over plain HTTP"
  export FLEET_SERVER_TLS=false
fi

LICENSE="$(opt .license_key)"
if [[ -n "$LICENSE" ]]; then export FLEET_LICENSE_KEY="$LICENSE"; fi

log "Running database migrations"
fleet prepare db --no-prompt </dev/null

fleet serve </dev/null &
FLEET_PID=$!

shutdown() {
  log "Shutting down"
  kill -TERM "$FLEET_PID" 2>/dev/null || true
  wait "$FLEET_PID" 2>/dev/null || true
  redis-cli -h 127.0.0.1 shutdown nosave >/dev/null 2>&1 || true
  mysqladmin --defaults-extra-file="$ROOT_CNF" shutdown 2>/dev/null || kill -TERM "$MYSQL_PID"
  wait "$MYSQL_PID" 2>/dev/null || true
  exit "${1:-0}"
}
trap 'shutdown 0' TERM INT

# If any of the three dies, bring the others down cleanly and let Supervisor restart us.
set +e
wait -n "$FLEET_PID" "$MYSQL_PID" "$REDIS_PID"
log "A child process exited unexpectedly"
shutdown 1
