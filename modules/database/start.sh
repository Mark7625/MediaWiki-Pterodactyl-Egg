#!/usr/bin/env bash
set -euo pipefail
trap 'echo -e "${RED}[Database] Error on line $LINENO${NC}"' ERR

BLUE='\033[0;34m'; BOLD_BLUE='\033[1;34m'
WHITE='\033[0;37m'; GREEN='\033[0;32m'
YELLOW='\033[0;33m'; RED='\033[0;31m'
NC='\033[0m'

header() { echo -e "${BLUE}───────────────────────────────────────────────${NC}"; echo -e "${BOLD_BLUE}[Database] $1${NC}"; }
is_enabled() { [[ "${1:-}" =~ ^(true|1)$ ]]; }

DB_STATUS="${DB_STATUS:-false}"
if ! is_enabled "$DB_STATUS"; then
  exit 0
fi

CONTAINER_ROOT="${CONTAINER_ROOT:-/home/container}"
# shellcheck source=../lib/secrets.sh
source "${CONTAINER_ROOT}/modules/lib/secrets.sh"

DB_PORT="${DB_PORT:-3306}"
DB_BIND_PUBLIC="${DB_BIND_PUBLIC:-0}"
DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD:-}"
DB_NAME="${DB_NAME:-}"
DB_USER="${DB_USER:-}"
DB_PASSWORD="${DB_PASSWORD:-}"

mw_ensure_secrets

MARIADB_BUNDLE="${CONTAINER_ROOT}/mariadb-bundle"
MYSQL_HOME="${MYSQL_HOME:-${CONTAINER_ROOT}/mysql}"
MYSQL_DATA="${MYSQL_HOME}/data"
MYSQL_RUN="${MYSQL_HOME}/run"
MYSQL_SOCKET="${MYSQL_RUN}/mysqld.sock"
MYSQL_PID="${MYSQL_RUN}/mysqld.pid"
MYSQL_CNF="${MYSQL_HOME}/my.cnf"
MYSQL_LOG="${CONTAINER_ROOT}/logs/mariadb.log"
DB_HOST="127.0.0.1"
USE_BUNDLE=0

setup_bundle_path() {
  if [[ ! -d "${MARIADB_BUNDLE}/bin" ]]; then
    return 1
  fi
  export PATH="${MARIADB_BUNDLE}/sbin:${MARIADB_BUNDLE}/bin:${PATH}"
  export LD_LIBRARY_PATH="${MARIADB_BUNDLE}/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
  USE_BUNDLE=1
  return 0
}

ensure_bundle_basedir_layout() {
  mkdir -p "${MARIADB_BUNDLE}/"{sbin,bin,share/mysql/extra,share/mariadb/extra}
  if [[ ! -x "${MARIADB_BUNDLE}/sbin/mariadbd" && -x "${MARIADB_BUNDLE}/bin/mariadbd" ]]; then
    ln -sf ../bin/mariadbd "${MARIADB_BUNDLE}/sbin/mariadbd" 2>/dev/null || true
  fi
  if [[ -d "${MARIADB_BUNDLE}/share/mariadb" && ! -e "${MARIADB_BUNDLE}/share/mysql" ]]; then
    ln -sfn mariadb "${MARIADB_BUNDLE}/share/mysql" 2>/dev/null || true
  elif [[ -d "${MARIADB_BUNDLE}/share/mysql" && ! -e "${MARIADB_BUNDLE}/share/mariadb" ]]; then
    ln -sfn mysql "${MARIADB_BUNDLE}/share/mariadb" 2>/dev/null || true
  fi
  ensure_bundle_install_db_extras
}

bundle_share_dir() {
  if [[ -d "${MARIADB_BUNDLE}/share/mariadb" ]]; then
    echo "${MARIADB_BUNDLE}/share/mariadb"
  elif [[ -d "${MARIADB_BUNDLE}/share/mysql" ]]; then
    echo "${MARIADB_BUNDLE}/share/mysql"
  else
    return 1
  fi
}

ensure_bundle_share_layout() {
  ensure_bundle_basedir_layout
}

bundle_mysql_share_root() {
  if [[ -d "${MARIADB_BUNDLE}/share/mysql" ]]; then
    echo "${MARIADB_BUNDLE}/share/mysql"
  elif [[ -d "${MARIADB_BUNDLE}/share/mariadb" ]]; then
    echo "${MARIADB_BUNDLE}/share/mariadb"
  else
    return 1
  fi
}

ensure_bundle_install_db_extras() {
  local mysql_share extra_dir
  mysql_share="$(bundle_mysql_share_root)" || return 1
  extra_dir="${mysql_share}/extra"
  mkdir -p "$extra_dir"
  if [[ -x "${extra_dir}/my_print_defaults" ]]; then
    return 0
  fi
  for src_extra in /usr/share/mysql/extra /usr/share/mariadb/extra; do
    [[ -d "$src_extra" ]] && cp -a "${src_extra}/." "$extra_dir/" 2>/dev/null || true
  done
  if [[ ! -x "${extra_dir}/my_print_defaults" && -x /usr/bin/my_print_defaults ]]; then
    cp -L /usr/bin/my_print_defaults "${extra_dir}/my_print_defaults" 2>/dev/null || true
    chmod +x "${extra_dir}/my_print_defaults" 2>/dev/null || true
  fi
  if [[ ! -x "${extra_dir}/my_print_defaults" && -x "${MARIADB_BUNDLE}/bin/my_print_defaults" ]]; then
    cp -L "${MARIADB_BUNDLE}/bin/my_print_defaults" "${extra_dir}/my_print_defaults" 2>/dev/null || true
    chmod +x "${extra_dir}/my_print_defaults" 2>/dev/null || true
  fi
}

system_install_db_ready() {
  [[ -x /usr/bin/mariadb-install-db ]] \
    && { [[ -x /usr/bin/my_print_defaults ]] \
      || [[ -x /usr/share/mariadb/extra/my_print_defaults ]] \
      || [[ -x /usr/share/mysql/extra/my_print_defaults ]]; }
}

mariadb_daemon() {
  if [[ "$USE_BUNDLE" -eq 1 ]]; then
    [[ -x "${MARIADB_BUNDLE}/sbin/mariadbd" ]] && echo "${MARIADB_BUNDLE}/sbin/mariadbd" && return
    [[ -x "${MARIADB_BUNDLE}/bin/mariadbd" ]] && echo "${MARIADB_BUNDLE}/bin/mariadbd" && return
  fi
  if command -v mariadbd >/dev/null 2>&1; then
    command -v mariadbd
    return
  fi
  [[ -x "${MARIADB_BUNDLE}/sbin/mariadbd" ]] && echo "${MARIADB_BUNDLE}/sbin/mariadbd" && return
  [[ -x "${MARIADB_BUNDLE}/bin/mariadbd" ]] && echo "${MARIADB_BUNDLE}/bin/mariadbd" && return
  command -v mysqld 2>/dev/null || true
}

mariadb_install_db_bin() {
  if command -v mariadb-install-db >/dev/null 2>&1; then
    command -v mariadb-install-db
    return
  fi
  [[ -x "${MARIADB_BUNDLE}/bin/mariadb-install-db" ]] && echo "${MARIADB_BUNDLE}/bin/mariadb-install-db" && return
  command -v mysql_install_db 2>/dev/null || true
}

mariadb_client() {
  if [[ "$USE_BUNDLE" -eq 1 && -x "${MARIADB_BUNDLE}/bin/mariadb" ]]; then
    echo "${MARIADB_BUNDLE}/bin/mariadb"
    return
  fi
  if command -v mariadb >/dev/null 2>&1; then
    command -v mariadb
    return
  fi
  [[ -x "${MARIADB_BUNDLE}/bin/mariadb" ]] && echo "${MARIADB_BUNDLE}/bin/mariadb" && return
  command -v mysql 2>/dev/null || echo mysql
}

mariadb_admin_bin() {
  if [[ "$USE_BUNDLE" -eq 1 && -x "${MARIADB_BUNDLE}/bin/mariadb-admin" ]]; then
    echo "${MARIADB_BUNDLE}/bin/mariadb-admin"
    return
  fi
  if command -v mariadb-admin >/dev/null 2>&1; then
    command -v mariadb-admin
    return
  fi
  [[ -x "${MARIADB_BUNDLE}/bin/mariadb-admin" ]] && echo "${MARIADB_BUNDLE}/bin/mariadb-admin" && return
  command -v mysqladmin 2>/dev/null || true
}

is_running() {
  local admin
  admin="$(mariadb_admin_bin)" || return 1
  [[ -n "$admin" ]] || return 1

  # Official egg uses socket ping; TCP ping aborts as "unauthenticated" on MariaDB 10.11.
  if [[ -S "$MYSQL_SOCKET" ]]; then
    "$admin" --socket="$MYSQL_SOCKET" --silent ping >/dev/null 2>&1 && return 0
  fi

  if [[ -f "$MYSQL_PID" ]] && kill -0 "$(cat "$MYSQL_PID" 2>/dev/null)" 2>/dev/null; then
    return 0
  fi

  return 1
}

mysql_cli() {
  local client connect_args=()
  client="$(mariadb_client)"
  if [[ -S "$MYSQL_SOCKET" ]]; then
    connect_args=(--socket="$MYSQL_SOCKET")
  else
    connect_args=(--protocol=TCP -h127.0.0.1 -P"${DB_PORT}")
  fi
  "$client" "${connect_args[@]}" "$@"
}

stop_mariadb() {
  local admin
  admin="$(mariadb_admin_bin)" || true
  if [[ -n "$admin" && -S "$MYSQL_SOCKET" ]]; then
    "$admin" --socket="$MYSQL_SOCKET" --silent shutdown >/dev/null 2>&1 || true
  fi
  if [[ -f "$MYSQL_PID" ]]; then
    kill "$(cat "$MYSQL_PID" 2>/dev/null)" 2>/dev/null || true
    for _ in $(seq 1 15); do
      kill -0 "$(cat "$MYSQL_PID" 2>/dev/null)" 2>/dev/null || break
      sleep 1
    done
  fi
  rm -f "$MYSQL_PID" "$MYSQL_SOCKET"
}

start_mariadb() {
  "$DAEMON" --defaults-file="$MYSQL_CNF" >>"$MYSQL_LOG" 2>&1 &
  for _ in $(seq 1 45); do
    is_running && break
    sleep 1
  done
  is_running
}

# Debian default unix_socket root cannot be used from the Pterodactyl container user.
bootstrap_root_password() {
  if mysql_cli -uroot -p"${DB_ROOT_PASSWORD}" -e "SELECT 1" >/dev/null 2>&1; then
    return 0
  fi
  if mysql_cli -uroot -e "SELECT 1" >/dev/null 2>&1; then
    mysql_cli -uroot -e "
      ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_ROOT_PASSWORD}';
      CREATE USER IF NOT EXISTS 'root'@'127.0.0.1' IDENTIFIED BY '${DB_ROOT_PASSWORD}';
      GRANT ALL PRIVILEGES ON *.* TO 'root'@'127.0.0.1' WITH GRANT OPTION;
      FLUSH PRIVILEGES;
    " >>"$MYSQL_LOG" 2>&1
    return 0
  fi

  echo -e "${YELLOW}[Database] Configuring root password (unix_socket → password auth)…${NC}"
  stop_mariadb

  "$DAEMON" --defaults-file="$MYSQL_CNF" --skip-grant-tables --skip-networking >>"$MYSQL_LOG" 2>&1 &
  for _ in $(seq 1 30); do
    [[ -S "$MYSQL_SOCKET" ]] && break
    sleep 1
  done

  mysql_cli -uroot mysql -e "
    FLUSH PRIVILEGES;
    ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_ROOT_PASSWORD}';
    CREATE USER IF NOT EXISTS 'root'@'127.0.0.1' IDENTIFIED BY '${DB_ROOT_PASSWORD}';
    GRANT ALL PRIVILEGES ON *.* TO 'root'@'127.0.0.1' WITH GRANT OPTION;
    FLUSH PRIVILEGES;
  " >>"$MYSQL_LOG" 2>&1 || {
    echo -e "${RED}[Database] Could not set root password. Last log lines:${NC}"
    tail -n 15 "$MYSQL_LOG" 2>/dev/null || true
    stop_mariadb
    exit 1
  }

  stop_mariadb
  start_mariadb || {
    echo -e "${RED}[Database] MariaDB did not restart after bootstrap.${NC}"
    tail -n 15 "$MYSQL_LOG" 2>/dev/null || true
    exit 1
  }
}

configure_database_users() {
  bootstrap_root_password

  mysql_cli -uroot -p"${DB_ROOT_PASSWORD}" -e "
    CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
    CREATE USER IF NOT EXISTS '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASSWORD}';
    CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';
    GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'127.0.0.1';
    GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
    FLUSH PRIVILEGES;
  " >>"$MYSQL_LOG" 2>&1
}

# Same check as official Pterodactyl MariaDB egg (user.frm) plus MariaDB 10.4+ layouts.
datadir_has_system_tables() {
  [[ -f "${MYSQL_DATA}/mysql/user.frm" ]] \
    || [[ -f "${MYSQL_DATA}/mysql/db.frm" ]] \
    || [[ -f "${MYSQL_DATA}/mysql/db.MAD" ]] \
    || [[ -f "${MYSQL_DATA}/mysql/db.ibd" ]] \
    || [[ -f "${MYSQL_DATA}/mysql/global_priv.MAD" ]]
}

datadir_is_corrupt() {
  if datadir_has_system_tables; then
    return 1
  fi
  [[ -f "${MYSQL_DATA}/ibdata1" ]] \
    || [[ -d "${MYSQL_DATA}/mysql" ]] \
    || [[ -f "${MYSQL_DATA}/ib_logfile0" ]]
}

wipe_datadir() {
  echo -e "${YELLOW}[Database] Removing incomplete data directory (will re-initialize)…${NC}"
  rm -rf "${MYSQL_DATA:?}"/*
  rm -f "${MYSQL_HOME}/.initialized"
  mkdir -p "$MYSQL_DATA"
  chmod 700 "$MYSQL_DATA" 2>/dev/null || true
}

init_datadir_failed() {
  echo -e "${RED}[Database] Data directory init failed.${NC}"
  local init_log="${MYSQL_LOG}.init"
  if [[ -f "$init_log" ]]; then
    echo -e "${YELLOW}[Database] Init log:${NC}"
    tail -n 40 "$init_log" 2>/dev/null || true
  fi
  exit 1
}

mariadb_install_db_extra_args() {
  local installer="$1"
  local -n _out="${2:?}"
  _out=()
  [[ -n "$installer" ]] || return 0
  if "$installer" --help 2>&1 | grep -q 'auth-root-authentication-method'; then
    _out=(--auth-root-authentication-method=normal)
  fi
}

init_datadir() {
  if datadir_is_corrupt; then
    wipe_datadir
  fi
  if datadir_has_system_tables; then
    return 0
  fi

  echo -e "${WHITE}[Database] Initializing data directory…${NC}"
  local init_log="${MYSQL_LOG}.init"
  : >"$init_log"

  local install_args=(--datadir="$MYSQL_DATA")
  local install_label="mariadb-install-db"
  local INSTALL_DB=""
  local rc=1

  # Official Pterodactyl egg: system install-db + datadir only (needs /usr in the image).
  if system_install_db_ready; then
    INSTALL_DB="/usr/bin/mariadb-install-db"
    install_label="system mariadb-install-db"
    local auth_args=()
    mariadb_install_db_extra_args "$INSTALL_DB" auth_args
    set +e
    "$INSTALL_DB" "${install_args[@]}" "${auth_args[@]}" >>"$init_log" 2>&1
    rc=$?
    set -e
    if [[ "$rc" -eq 0 ]] && datadir_has_system_tables; then
      echo -e "${GREEN}[Database] Data directory initialized (${install_label}).${NC}"
      return 0
    fi
    echo "[Database] ${install_label} failed (exit ${rc}), trying bundle…" >>"$init_log"
    if datadir_is_corrupt; then
      wipe_datadir
    fi
  fi

  if [[ ! -d "${MARIADB_BUNDLE}/bin" ]]; then
    echo "[Database] No mariadb-bundle for fallback" >>"$init_log"
    init_datadir_failed
  fi
  setup_bundle_path || true
  ensure_bundle_share_layout
  if [[ ! -x "${MARIADB_BUNDLE}/sbin/mariadbd" ]]; then
    echo -e "${RED}[Database] Bundle missing sbin/mariadbd (incomplete basedir).${NC}"
    echo -e "${RED}[Database] Delete ${MARIADB_BUNDLE}/.bundled and reinstall the server.${NC}"
    init_datadir_failed
  fi
  if [[ ! -x "${MARIADB_BUNDLE}/share/mariadb/extra/my_print_defaults" \
    && ! -x "${MARIADB_BUNDLE}/share/mysql/extra/my_print_defaults" ]]; then
    echo -e "${RED}[Database] Bundle missing share/mysql/extra/my_print_defaults.${NC}"
    echo -e "${RED}[Database] Delete ${MARIADB_BUNDLE}/.bundled and reinstall, or rebuild the Docker image with MariaDB.${NC}"
    init_datadir_failed
  fi

  INSTALL_DB="${MARIADB_BUNDLE}/bin/mariadb-install-db"
  [[ -x "$INSTALL_DB" ]] || INSTALL_DB="$(mariadb_install_db_bin)"
  [[ -n "$INSTALL_DB" ]] || init_datadir_failed

  install_args+=(--basedir="${MARIADB_BUNDLE}")
  install_label="bundled mariadb-install-db"
  local auth_args=()
  mariadb_install_db_extra_args "$INSTALL_DB" auth_args

  set +e
  "$INSTALL_DB" "${install_args[@]}" "${auth_args[@]}" >>"$init_log" 2>&1
  rc=$?
  set -e

  if [[ "$rc" -eq 0 ]] && datadir_has_system_tables; then
    echo -e "${GREEN}[Database] Data directory initialized (${install_label}).${NC}"
    return 0
  fi

  echo "[Database] ${install_label} failed (exit ${rc})" >>"$init_log"
  init_datadir_failed
}

# Prefer system MariaDB from the Docker image (matches official egg behaviour).
if command -v mariadbd >/dev/null 2>&1 && system_install_db_ready; then
  header "MariaDB on this server (127.0.0.1:${DB_PORT}) — image MariaDB"
  USE_BUNDLE=0
elif setup_bundle_path; then
  header "MariaDB on this server (127.0.0.1:${DB_PORT}) — volume bundle"
  ensure_bundle_share_layout
else
  echo -e "${RED}[Database] No MariaDB found (rebuild Docker image or reinstall mariadb-bundle).${NC}"
  exit 1
fi

DAEMON="$(mariadb_daemon)"
[[ -n "$DAEMON" ]] || { echo -e "${RED}[Database] mariadbd not found.${NC}"; exit 1; }

mkdir -p "$MYSQL_DATA" "$MYSQL_RUN" "${CONTAINER_ROOT}/logs"
chmod 700 "$MYSQL_DATA" "$MYSQL_RUN" 2>/dev/null || true

if is_enabled "$DB_BIND_PUBLIC"; then
  DB_BIND_ADDRESS="0.0.0.0"
else
  DB_BIND_ADDRESS="127.0.0.1"
fi

if [[ -f "$MYSQL_PID" ]] && ! kill -0 "$(cat "$MYSQL_PID")" 2>/dev/null; then
  rm -f "$MYSQL_PID" "$MYSQL_SOCKET"
fi

init_datadir

PLUGIN_LINE=""
if [[ "$USE_BUNDLE" -eq 1 && -d "${MARIADB_BUNDLE}/plugin" ]]; then
  PLUGIN_LINE="plugin-dir=${MARIADB_BUNDLE}/plugin"
elif [[ -d /usr/lib/mysql/plugin ]]; then
  PLUGIN_LINE="plugin-dir=/usr/lib/mysql/plugin"
fi

BASEDIR_LINE=""
if [[ "$USE_BUNDLE" -eq 1 ]]; then
  BASEDIR_LINE="basedir=${MARIADB_BUNDLE}"
fi

LC_MESSAGES_LINE=""
if [[ "$USE_BUNDLE" -eq 1 && -d "${MARIADB_BUNDLE}/share/mariadb" ]]; then
  LC_MESSAGES_LINE="lc-messages-dir=${MARIADB_BUNDLE}/share/mariadb"
elif [[ -d /usr/share/mariadb ]]; then
  LC_MESSAGES_LINE="lc-messages-dir=/usr/share/mariadb"
fi

cat >"$MYSQL_CNF" <<EOF
[mysqld]
${BASEDIR_LINE}
datadir=${MYSQL_DATA}
port=${DB_PORT}
bind-address=${DB_BIND_ADDRESS}
socket=${MYSQL_SOCKET}
pid-file=${MYSQL_PID}
log-error=${MYSQL_LOG}
skip-name-resolve
innodb_use_native_aio=0
character-set-server=utf8mb4
collation-server=utf8mb4_unicode_ci
${PLUGIN_LINE}
${LC_MESSAGES_LINE}

[client]
socket=${MYSQL_SOCKET}
port=${DB_PORT}

[mysqladmin]
socket=${MYSQL_SOCKET}
EOF

if ! is_running; then
  echo -e "${WHITE}[Database] Starting MariaDB…${NC}"
  start_mariadb || {
    echo -e "${RED}[Database] MariaDB did not start. Last log lines:${NC}"
    tail -n 15 "$MYSQL_LOG" 2>/dev/null || true
    exit 1
  }
fi
echo -e "${GREEN}[Database] Listening on ${DB_BIND_ADDRESS}:${DB_PORT} (wiki uses 127.0.0.1)${NC}"

if [[ ! -f "${MYSQL_HOME}/.initialized" ]]; then
  echo -e "${WHITE}[Database] Creating database and user…${NC}"
  configure_database_users
  touch "${MYSQL_HOME}/.initialized"
  echo -e "${GREEN}[Database] Ready: ${DB_NAME} / ${DB_USER}${NC}"
fi

export DB_HOST DB_PORT DB_NAME DB_USER DB_PASSWORD DB_ROOT_PASSWORD

# Written for other modules (subshell exports do not reach the orchestrator).
umask 077
cat >"${CONTAINER_ROOT}/.db-env" <<EOF
DB_HOST='${DB_HOST}'
DB_PORT='${DB_PORT}'
DB_NAME='${DB_NAME}'
DB_USER='${DB_USER}'
DB_PASSWORD='${DB_PASSWORD}'
DB_ROOT_PASSWORD='${DB_ROOT_PASSWORD}'
EOF
chmod 600 "${CONTAINER_ROOT}/.db-env" 2>/dev/null || true
