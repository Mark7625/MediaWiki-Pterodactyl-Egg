#!/usr/bin/env bash
set -euo pipefail
trap 'echo -e "${YELLOW}[Startup] Error on line $LINENO${NC}"' ERR

# Color definitions
RED='\033[0;31m'
BLUE='\033[0;34m'; BOLD_BLUE='\033[1;34m'
WHITE='\033[0;37m'; GREEN='\033[0;32m'
YELLOW='\033[0;33m'; CYAN='\033[1;36m'
UNDERLINE='\033[4m'; NC='\033[0m'

# Header function
header() {
  echo -e "${BLUE}───────────────────────────────────────────────${NC}"
  echo -e "${BOLD_BLUE}$1${NC}"
}

# Configurable paths/files via env vars with defaults
PHP_VERSION="${PHP_VERSION:-8.4}"
PHP_INI="${PHP_INI:-/home/container/php/php.ini}"
PHP_FPM_CONF="${PHP_FPM_CONF:-/home/container/php/php-fpm.conf}"
NGINX_CONF="${NGINX_CONF:-/home/container/nginx/nginx.conf}"
NGINX_PREFIX="${NGINX_PREFIX:-/home/container}"

# shellcheck source=../lib/php-fpm.sh
source "${NGINX_PREFIX}/modules/lib/php-fpm.sh"

header "[Startup] Starting PHP-FPM"
echo -e "${WHITE}[Startup] PHP ${PHP_VERSION} (image tag should match, e.g. mediawiki-pterodactyl-egg:${PHP_VERSION}-latest)${NC}"
if ! php_fpm_start_if_needed "$NGINX_PREFIX" "$PHP_INI" "$PHP_FPM_CONF"; then
  exit 1
fi

if [[ -f "${NGINX_PREFIX}/modules/lib/php-mediawiki-setup.sh" ]]; then
  # shellcheck source=../lib/php-mediawiki-setup.sh
  source "${NGINX_PREFIX}/modules/lib/php-mediawiki-setup.sh"
  php_mediawiki_verify_extensions "$NGINX_PREFIX"
fi

# Success message
echo -e "${GREEN}[Startup] Services successfully launched!${NC}"

# Brief pause
sleep 1

# Footer
echo -e " "
echo -e "\033[0;34m───────────────────────────────────────────────\033[0m"
echo -e "\033[1;36mMediaWiki Pterodactyl Egg — \033[4;34mhttps://github.com/Mark7625/MediaWiki-Pterodactyl-Egg\033[0m"
echo -e "\033[1;36mMIT License — see LICENSE and README (Credits)\033[0m"
echo -e "\033[0;34m───────────────────────────────────────────────\033[0m"

# Stop background nginx from MediaWiki pre-install (started with daemon on) before foreground bind.
if [[ -f "${NGINX_PREFIX}/tmp/nginx.pid" ]]; then
  nginx -s quit -c "$NGINX_CONF" -p "$NGINX_PREFIX" 2>/dev/null || true
  sleep 1
fi

# Start NGINX (daemon off — keeps container alive)
nginx -c "$NGINX_CONF" -p "$NGINX_PREFIX" -e /dev/stderr
