#!/usr/bin/env bash
# Start PHP-FPM + nginx (background) for installer HTTP checks. Safe to call if already running.

web_stack_http_ok() {
  local url="$1"
  if command -v curl >/dev/null 2>&1; then
    curl -sf --max-time 3 "$url" -o /dev/null 2>/dev/null
    return $?
  fi
  if command -v wget >/dev/null 2>&1; then
    wget -q --timeout=3 -O /dev/null "$url" 2>/dev/null
    return $?
  fi
  return 1
}

web_stack_ensure_running() {
  local container_root="${1:-/home/container}"
  local check_url="${2:-http://127.0.0.1/images/README}"

  if web_stack_http_ok "$check_url"; then
    return 0
  fi

  # shellcheck source=php-fpm.sh
  source "${container_root}/modules/lib/php-fpm.sh"
  php_fpm_start_if_needed "$container_root" \
    "${container_root}/php/php.ini" \
    "${container_root}/php/php-fpm.conf" || true

  # nginx.conf uses "daemon off" for the main panel process — override so we do not block install.
  nginx -g 'daemon on;' \
    -c "${container_root}/nginx/nginx.conf" \
    -p "${container_root}" >/dev/null 2>&1 || true

  local i=0
  while [[ "$i" -lt 10 ]]; do
    if web_stack_http_ok "$check_url"; then
      return 0
    fi
    sleep 1
    i=$((i + 1))
  done
  return 1
}
