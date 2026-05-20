#!/usr/bin/env bash
# Shared PHP-FPM helpers (sourced, not executed).

php_fpm_resolve_binary() {
  local version="${PHP_VERSION:-8.4}"
  if command -v "php-fpm${version}" >/dev/null 2>&1; then
    PHP_FPM_BIN="php-fpm${version}"
    return 0
  fi
  if command -v php-fpm >/dev/null 2>&1; then
    PHP_FPM_BIN=php-fpm
    return 0
  fi
  return 1
}

php_fpm_paths() {
  local root="${1:-/home/container}"
  PHP_FPM_PID_FILE="${root}/logs/php-fpm.pid"
  PHP_FPM_SOCKET="${root}/tmp/php-fpm.sock"
  PHP_FPM_ERROR_LOG="${root}/logs/php-fpm.log"
}

php_fpm_is_running() {
  local root="${1:-/home/container}"
  php_fpm_paths "$root"
  if [[ -S "$PHP_FPM_SOCKET" ]]; then
    return 0
  fi
  if [[ -f "$PHP_FPM_PID_FILE" ]]; then
    local pid
    pid=$(tr -d '[:space:]' <"$PHP_FPM_PID_FILE" 2>/dev/null || true)
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      return 0
    fi
  fi
  return 1
}

# Start PHP-FPM only if not already running (e.g. after MediaWiki pre-install).
php_fpm_start_if_needed() {
  local root="${1:-/home/container}"
  local php_ini="${2:-${root}/php/php.ini}"
  local fpm_conf="${3:-${root}/php/php-fpm.conf}"

  if [[ -f "${root}/modules/lib/php-mediawiki-setup.sh" ]]; then
    # shellcheck source=php-mediawiki-setup.sh
    source "${root}/modules/lib/php-mediawiki-setup.sh"
    php_mediawiki_configure "$root"
  fi

  php_fpm_paths "$root"
  mkdir -p "${root}/tmp" "${root}/logs"

  if php_fpm_is_running "$root"; then
    echo -e "\033[0;32m[PHP-FPM] Already running (${PHP_FPM_SOCKET})\033[0m"
    return 0
  fi

  if ! php_fpm_resolve_binary; then
    echo -e "\033[0;31m[PHP-FPM] php-fpm${PHP_VERSION:-8.4} not found — match PHP_VERSION to your Docker image tag\033[0m"
    return 1
  fi

  # Stale pid file with no socket
  [[ -f "$PHP_FPM_PID_FILE" ]] && rm -f "$PHP_FPM_PID_FILE"

  if "$PHP_FPM_BIN" -c "$php_ini" --fpm-config "$fpm_conf" -D 2>>"${root}/logs/php-fpm-start.log"; then
    local i=0
    while [[ "$i" -lt 5 ]]; do
      if php_fpm_is_running "$root"; then
        return 0
      fi
      sleep 1
      i=$((i + 1))
    done
  fi

  echo -e "\033[0;31m[PHP-FPM] Failed to start ${PHP_FPM_BIN} (PHP ${PHP_VERSION:-?})\033[0m"
  echo -e "\033[0;33m[PHP-FPM] Ensure Docker image tag matches PHP_VERSION (e.g. mediawiki-pterodactyl-egg:8.2-latest → 8.2)\033[0m"
  if [[ -f "${root}/logs/php-fpm-start.log" ]]; then
    echo -e "\033[0;33m[PHP-FPM] Last start log lines:\033[0m"
    tail -n 8 "${root}/logs/php-fpm-start.log" 2>/dev/null || true
  fi
  if [[ -f "$PHP_FPM_ERROR_LOG" ]]; then
    tail -n 8 "$PHP_FPM_ERROR_LOG" 2>/dev/null || true
  fi
  return 1
}
