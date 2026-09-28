#!/usr/bin/env bash
set -euo pipefail

OPTS=/data/options.json
opt() { jq -r "$1 // empty" "$OPTS"; }
log() { echo "[fleet-app] $*"; }

SOCK=/run/mysqld/mysqld.sock
CNF=/etc/fleet-mysql.cnf
SECRETS=/data/secrets
ROOT_CNF=/run/mysqld/root.cnf
TLS_DIR=/data/tls

MYSQL_PID="" REDIS_PID="" FLEET_PID=""

shutdown() {
  trap - TERM INT
  log "Shutting down"
  [[ -n "$FLEET_PID" ]] && { kill -TERM "$FLEET_PID" 2>/dev/null; wait "$FLEET_PID" 2>/dev/null; }
  [[ -n "$REDIS_PID" ]] && redis-cli -h 127.0.0.1 shutdown nosave >/dev/null 2>&1
  if [[ -n "$MYSQL_PID" ]]; then
    mysqladmin --defaults-extra-file="$ROOT_CNF" shutdown 2>/dev/null || kill -TERM "$MYSQL_PID" 2>/dev/null
    wait "$MYSQL_PID" 2>/dev/null
  fi
  exit "${1:-0}"
}
trap 'shutdown 0' TERM INT
fail() { log "ERROR: $*"; shutdown 1; }

# ---------- Validate options and TLS before starting anything ----------
if [[ "$(opt .ssl)" == "true" ]]; then
  CERT="/ssl/$(opt .certfile)"
  KEY="/ssl/$(opt .keyfile)"
  if [[ ! -r "$CERT" || ! -r "$KEY" ]]; then
    mapfile -t NAMES < <(jq -r '.tls_hostnames // [] | .[]' "$OPTS")
    (( ${#NAMES[@]} )) || fail "No cert at $CERT/$KEY and tls_hostnames is empty"
    SAN=""
    for n in "${NAMES[@]}"; do
      if [[ "$n" =~ ^[0-9.]+$ || "$n" == *:* ]]; then SAN+="IP:$n,"; else SAN+="DNS:$n,"; fi
    done
    SAN="${SAN%,}"
    CERT="$TLS_DIR/server.crt" KEY="$TLS_DIR/server.key"
    mkdir -p "$TLS_DIR"
    # Regenerate only when the SAN list changes, so enrolled agents keep trusting it.
    if [[ ! -s "$CERT" || "$(cat "$TLS_DIR/san" 2>/dev/null)" != "$SAN" ]]; then
      log "No cert in /ssl; generating self-signed cert for $SAN"
      openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
        -days 3650 -subj "/CN=${NAMES[0]}" -addext "subjectAltName=$SAN" \
        -keyout "$KEY" -out "$CERT" 2>/dev/null || fail "openssl failed"
      chmod 600 "$KEY"; echo "$SAN" > "$TLS_DIR/san"
    fi
    log "Using self-signed cert. Build agents with: fleetctl package ... --fleet-certificate=<copy of $CERT>"
  fi
  export FLEET_SERVER_TLS=true FLEET_SERVER_CERT="$CERT" FLEET_SERVER_KEY="$KEY"
else
  log "TLS disabled: terminate TLS at a reverse proxy; fleetd will not enroll over plain HTTP"
  export FLEET_SERVER_TLS=false
fi

# ---------- Secrets ----------
mkdir -p "$SECRETS" /data/logs /data/tmp /data/mysql /run/mysqld
chmod 700 "$SECRETS"
chown mysql:mysql /data/mysql /run/mysqld
chmod 750 /run/mysqld

gen_secret() {  # file, bytes
  [[ -s "$1" ]] || { openssl rand -base64 "$2" | tr -d '\n' > "$1"; chmod 600 "$1"; }
}
gen_secret "$SECRETS/mysql_root_password" 24
gen_secret "$SECRETS/mysql_fleet_password" 24
gen_secret "$SECRETS/server_private_key" 32   # Fleet: >= 32 bytes, must never change

ROOT_PW=$(<"$SECRETS/mysql_root_password")
FLEET_PW=$(<"$SECRETS/mysql_fleet_password")

# ---------- MySQL ----------
FIRST_RUN=0
if [[ ! -d /data/mysql/mysql ]]; then
  log "Initializing MySQL datadir"
  mysqld --defaults-file="$CNF" --initialize-insecure --user=mysql
  FIRST_RUN=1
fi

mysqld --defaults-file="$CNF" --user=mysql \
       --innodb-buffer-pool-size="$(opt .innodb_buffer_pool_mb)M" &
MYSQL_PID=$!

for _ in $(seq 1 90); do
  # ping exits 0 once the server answers, even if auth is refused
  mysqladmin --socket="$SOCK" ping --silent >/dev/null 2>&1 && break
  kill -0 "$MYSQL_PID" 2>/dev/null || { MYSQL_PID=""; fail "mysqld exited during startup"; }
  sleep 1
done

if (( FIRST_RUN )); then
  mysql --socket="$SOCK" -uroot --skip-password <<SQL
ALTER USER 'root'@'localhost' IDENTIFIED BY '${ROOT_PW}';
SQL
fi

umask 077
printf '[client]\nuser=root\npassword=%s\nsocket=%s\n' "$ROOT_PW" "$SOCK" > "$ROOT_CNF"
umask 022

mysql --defaults-extra-file="$ROOT_CNF" <<SQL || fail "MySQL user/database setup failed"
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
# Without S3 configured, Fleet keeps uploaded installers under os.TempDir().
export TMPDIR=/data/tmp

LICENSE="$(opt .license_key)"
if [[ -n "$LICENSE" ]]; then export FLEET_LICENSE_KEY="$LICENSE"; fi

log "Running database migrations"
fleet prepare db --no-prompt </dev/null || fail "fleet prepare db failed"

fleet serve </dev/null &
FLEET_PID=$!

# If any child dies, stop the others cleanly and let Supervisor restart the app.
set +e
wait -n "$FLEET_PID" "$MYSQL_PID" "$REDIS_PID"
log "A child process exited unexpectedly"
shutdown 1
