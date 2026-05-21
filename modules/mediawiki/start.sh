#!/usr/bin/env bash
set -euo pipefail
trap 'echo -e "${RED}[MediaWiki] Error on line $LINENO${NC}"' ERR

BLUE='\033[0;34m'; BOLD_BLUE='\033[1;34m'
WHITE='\033[0;37m'; GREEN='\033[0;32m'
YELLOW='\033[0;33m'; RED='\033[0;31m'
NC='\033[0m'

header() {
  echo -e "${BLUE}───────────────────────────────────────────────${NC}"
  echo -e "${BOLD_BLUE}[MediaWiki] $1${NC}"
}

is_enabled() { [[ "${1:-}" =~ ^(true|1)$ ]]; }

AUTOINSTALL_STATUS="${AUTOINSTALL_STATUS:-false}"

CONTAINER_ROOT="${CONTAINER_ROOT:-/home/container}"
MW_LIB_DIR="${CONTAINER_ROOT}/modules/lib"
# shellcheck source=../lib/secrets.sh
source "${MW_LIB_DIR}/secrets.sh"

WWW_DIR="${WWW_DIR:-${CONTAINER_ROOT}/www}"
PHP_VERSION="${PHP_VERSION:-8.4}"
DB_HOST="${DB_HOST:-}"
DB_PORT="${DB_PORT:-3306}"
DB_NAME="${DB_NAME:-}"
DB_USER="${DB_USER:-}"
DB_PASSWORD="${DB_PASSWORD:-}"
MW_SITE_NAME="${MW_SITE_NAME:-My Wiki}"
MW_ADMIN_USER="${MW_ADMIN_USER:-admin}"
MW_ADMIN_PASS="${MW_ADMIN_PASS:-}"
MW_UPDATE="${MW_UPDATE:-false}"

MW_LANG="${MW_LANG:-en}"
MW_SERVER="${MW_SERVER:-}"
MW_EXTENSIONS="${MW_EXTENSIONS:-}"
MW_EXTENSION_BRANCH="${MW_EXTENSION_BRANCH:-REL1_45}"
MW_SKINS="${MW_SKINS:-}"
MW_SKIN_BRANCH="${MW_SKIN_BRANCH:-REL1_45}"
REDIS_STATUS="${REDIS_STATUS:-0}"
REDIS_HOST="${REDIS_HOST:-127.0.0.1}"
REDIS_PORT="${REDIS_PORT:-6379}"
ELASTICSEARCH_STATUS="${ELASTICSEARCH_STATUS:-0}"
ELASTICSEARCH_HOST="${ELASTICSEARCH_HOST:-127.0.0.1:9200}"

DB_STATUS="${DB_STATUS:-true}"

require_db_var() {
  local name="$1" value="$2"
  if [[ -z "${value// }" ]]; then
    echo -e "${RED}[MediaWiki] ${name} is required. Set it in the panel or leave blank to auto-generate.${NC}"
    exit 1
  fi
}

mw_ensure_secrets

if [[ -f "${CONTAINER_ROOT}/.db-env" ]]; then
  # shellcheck disable=SC1090
  source "${CONTAINER_ROOT}/.db-env"
fi

DB_PORT="${DB_PORT//[[:space:]]/}"

if is_enabled "$DB_STATUS"; then
  if [[ -n "${DB_HOST// }" && "${DB_HOST}" != "127.0.0.1" && "${DB_HOST,,}" != "localhost" ]]; then
    echo -e "${YELLOW}[MediaWiki] Panel DB_HOST (${DB_HOST}) ignored — bundled MariaDB is 127.0.0.1 only, not your public web IP.${NC}"
  fi
  DB_HOST="127.0.0.1"
  echo -e "${WHITE}[MediaWiki] Using bundled database at ${DB_HOST}:${DB_PORT}${NC}"
else
  DB_INSTALL_USER="${DB_USER}"
  DB_INSTALL_PASS="${DB_PASSWORD}"
  require_db_var "DB_HOST" "$DB_HOST"
  DB_HOST="${DB_HOST//[[:space:]]/}"
  if [[ "$DB_HOST" == *:* ]]; then
    DB_PORT="${DB_HOST##*:}"
    DB_HOST="${DB_HOST%%:*}"
  fi
  if [[ "${DB_HOST,,}" == "localhost" ]]; then
    DB_HOST="127.0.0.1"
  fi
  require_db_var "DB_NAME" "$DB_NAME"
  require_db_var "DB_USER" "$DB_USER"
  require_db_var "DB_PASSWORD" "$DB_PASSWORD"
fi

mw_resolve_server_url() {
  MW_SERVER="${MW_SERVER//[[:space:]]/}"
  if [[ -z "$MW_SERVER" ]]; then
    if [[ -n "${SERVER_IP:-}" && -n "${SERVER_PORT:-}" ]]; then
      MW_SERVER="http://${SERVER_IP}:${SERVER_PORT}"
    else
      MW_SERVER="http://127.0.0.1:80"
    fi
  fi
  MW_SERVER="${MW_SERVER%/}"
  case "$MW_SERVER" in
    http://*|https://*) ;;
    *)
      echo -e "${RED}[MediaWiki] MW_SERVER must start with http:// or https:// (got: ${MW_SERVER})${NC}"
      exit 1
      ;;
  esac
}

mw_resolve_php_bin() {
  if [[ -n "${PHP_BIN:-}" ]]; then
    return 0
  fi
  if command -v "php${PHP_VERSION}" >/dev/null 2>&1; then
    PHP_BIN="php${PHP_VERSION}"
  elif command -v php >/dev/null 2>&1; then
    PHP_BIN=php
  else
    echo -e "${RED}[MediaWiki] PHP not found.${NC}"
    exit 1
  fi
}

mw_find_composer() {
  if command -v composer >/dev/null 2>&1; then
    echo "composer"
  elif [[ -x "/usr/local/bin/composer" ]]; then
    echo "/usr/local/bin/composer"
  elif [[ -x "/usr/bin/composer" ]]; then
    echo "/usr/bin/composer"
  else
    return 1
  fi
}

mw_install_extension_composer_dependencies() {
  local composer_bin
  if ! composer_bin="$(mw_find_composer)"; then
    echo -e "${YELLOW}[MediaWiki] composer CLI not available; skipping extension composer installs${NC}"
    return 0
  fi

  local ext_dir
  local installed=0

  for ext_dir in "${WWW_DIR}/extensions/"*; do
    [[ -d "$ext_dir" ]] || continue
    [[ -f "${ext_dir}/composer.json" ]] || continue

    echo -e "${WHITE}[MediaWiki] Running composer install for extension ${ext_dir##*/}…${NC}"
      if (cd "$ext_dir" && COMPOSER_MEMORY_LIMIT=-1 "$composer_bin" install --no-dev --optimize-autoloader --no-interaction --prefer-dist --no-progress -o 2>&1 | tail -n 100); then
        echo -e "${GREEN}[MediaWiki]   ✓ ${ext_dir##*/}${NC}"
      else
        echo -e "${YELLOW}[MediaWiki]   Warning: composer install failed for ${ext_dir##*/}. It may have missing dependencies or network/auth prompts.${NC}"
      fi
    installed=1
  done

  if [[ "$installed" -eq 0 ]]; then
    echo -e "${WHITE}[MediaWiki] No extensions with composer.json found; skipping extension composer installs${NC}"
  fi
}

mw_update_mode() {
  echo -e "${WHITE}[MediaWiki] Update mode: pulling git extensions and running composer installs${NC}"
  local composer_bin
  if composer_bin="$(mw_find_composer)" 2>/dev/null; then
    echo -e "${WHITE}[MediaWiki] composer CLI found: ${composer_bin}${NC}"
  else
    composer_bin=""
    echo -e "${YELLOW}[MediaWiki] composer CLI not found; will skip composer installs${NC}"
  fi

  local ext_dir
  for ext_dir in "${WWW_DIR}/extensions/"*; do
    [[ -d "$ext_dir" ]] || continue
    local name
    name="${ext_dir##*/}"
    if [[ -d "${ext_dir}/.git" ]]; then
      echo -e "${WHITE}[MediaWiki] Pulling git for extension ${name}...${NC}"
      git -C "$ext_dir" pull --ff-only 2>/dev/null || git -C "$ext_dir" fetch --all --prune || true
    fi

    if [[ -n "${composer_bin}" && -f "${ext_dir}/composer.json" ]]; then
      echo -e "${WHITE}[MediaWiki] Running composer install for extension ${name}...${NC}"
      (cd "$ext_dir" && COMPOSER_MEMORY_LIMIT=-1 "$composer_bin" install --no-dev --optimize-autoloader --no-interaction --prefer-dist --no-progress -o 2>&1 | tail -n 100) || echo -e "${YELLOW}[MediaWiki] composer failed for ${name}${NC}"
    fi
  done

  if [[ -n "${composer_bin}" && -f "${WWW_DIR}/composer.json" ]]; then
    echo -e "${WHITE}[MediaWiki] Running composer install for wiki root...${NC}"
    (cd "${WWW_DIR}" && COMPOSER_MEMORY_LIMIT=-1 "$composer_bin" install --no-dev --optimize-autoloader --no-interaction --prefer-dist --no-progress -o 2>&1 | tail -n 100) || echo -e "${YELLOW}[MediaWiki] composer install failed at wiki root${NC}"
  fi

  echo -e "${GREEN}[MediaWiki] Update mode finished${NC}"
}

mw_local_php_ext_dirs() {
  mkdir -p "${CONTAINER_ROOT}/php/extensions" "${CONTAINER_ROOT}/php/conf.d"
}

mw_phpize_bin() {
  if command -v "phpize${PHP_VERSION}" >/dev/null 2>&1; then
    echo "phpize${PHP_VERSION}"
  elif command -v phpize >/dev/null 2>&1; then
    echo phpize
  else
    return 1
  fi
}

mw_php_config_bin() {
  if command -v "php-config${PHP_VERSION}" >/dev/null 2>&1; then
    echo "php-config${PHP_VERSION}"
  elif command -v php-config >/dev/null 2>&1; then
    echo php-config
  else
    return 1
  fi
}

mw_build_user_extension() {
  local name="$1" pkg="$2" url="$3"
  local ext_dir="${CONTAINER_ROOT}/php/extensions"
  local conf_dir="${CONTAINER_ROOT}/php/conf.d"
  local tmp_dir="/tmp/${name}-build"
  rm -rf "$tmp_dir"
  mkdir -p "$tmp_dir"
  pushd "$tmp_dir" >/dev/null 2>&1 || return 1

  if [[ -n "$url" ]]; then
    wget -q -O "${name}.tar.gz" "$url" || { popd >/dev/null 2>&1; return 1; }
    tar -xzf "${name}.tar.gz" --strip-components=1
  else
    pecl download "${pkg:-$name}" || { popd >/dev/null 2>&1; return 1; }
    tarball=$(ls *.tgz 2>/dev/null | head -n 1)
    if [[ -z "$tarball" ]]; then
      tarball=$(ls *.tar.gz 2>/dev/null | head -n 1)
    fi
    [[ -n "$tarball" ]] || { popd >/dev/null 2>&1; return 1; }
    tar -xzf "$tarball" --strip-components=1
  fi

  local phpize_bin
  phpize_bin=$(mw_phpize_bin) || { popd >/dev/null 2>&1; return 1; }
  local php_config_bin
  php_config_bin=$(mw_php_config_bin) || { popd >/dev/null 2>&1; return 1; }

  "$phpize_bin" || { popd >/dev/null 2>&1; return 1; }
  ./configure --with-php-config="/usr/bin/$php_config_bin" || { popd >/dev/null 2>&1; return 1; }
  make -j"$(nproc)" || { popd >/dev/null 2>&1; return 1; }

  local built_so=".libs/${name}.so"
  if [[ ! -f "$built_so" ]]; then
    built_so="modules/${name}.so"
  fi
  [[ -f "$built_so" ]] || { popd >/dev/null 2>&1; return 1; }

  cp "$built_so" "$ext_dir/" || { popd >/dev/null 2>&1; return 1; }
  echo "extension=${ext_dir}/${name}.so" >"${conf_dir}/20-${name}.ini"
  popd >/dev/null 2>&1
  return 0
}

mw_db_mysqli_server() {
  if [[ "${DB_PORT}" == "3306" ]]; then
    echo "${DB_HOST}"
  else
    echo "${DB_HOST}:${DB_PORT}"
  fi
}

# Sync panel/env into LocalSettings on every start (URL, DB, site name).
mw_sync_localsettings_from_panel() {
  local settings="$1"
  [[ -f "$settings" ]] || return 0

  mw_resolve_php_bin
  local sync_php
  sync_php="${MW_LIB_DIR}/sync-localsettings.php"
  [[ -f "$sync_php" ]] || {
    echo -e "${YELLOW}[MediaWiki] sync-localsettings.php missing; skipping settings sync${NC}"
    return 0
  }

  require_db_var "DB_NAME" "$DB_NAME"
  require_db_var "DB_USER" "$DB_USER"
  require_db_var "DB_PASSWORD" "$DB_PASSWORD"

  local db_server
  db_server="$(mw_db_mysqli_server)"
  export MW_SERVER MW_DB_SERVER="${db_server}" MW_DB_NAME="${DB_NAME}" \
    MW_DB_USER="${DB_USER}" MW_DB_PASSWORD="${DB_PASSWORD}" \
    MW_SITE_NAME="${MW_SITE_NAME:-}" MW_LANG="${MW_LANG:-}"

  local json
  json=$("$PHP_BIN" -r '
$out = [
  "wgServer" => getenv("MW_SERVER") ?: "",
  "wgCanonicalServer" => getenv("MW_SERVER") ?: "",
  "wgScriptPath" => "",
  "wgScript" => "/index.php",
  "wgArticlePath" => "/w/$1",
  "wgMainPageIsDomainRoot" => true,
  "wgDBserver" => getenv("MW_DB_SERVER") ?: "",
  "wgDBname" => getenv("MW_DB_NAME") ?: "",
  "wgDBuser" => getenv("MW_DB_USER") ?: "",
  "wgDBpassword" => getenv("MW_DB_PASSWORD") ?: "",
];
$sitename = getenv("MW_SITE_NAME");
if ($sitename !== false && $sitename !== "") {
  $out["wgSitename"] = $sitename;
}
$lang = getenv("MW_LANG");
if ($lang !== false && $lang !== "") {
  $out["wgLanguageCode"] = $lang;
}
echo json_encode($out, JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR);
' 2>/dev/null) || {
    echo -e "${RED}[MediaWiki] Failed to build LocalSettings sync payload${NC}"
    return 1
  }

  if ! echo "$json" | "$PHP_BIN" "$sync_php" "$settings"; then
    echo -e "${RED}[MediaWiki] Failed to update LocalSettings.php${NC}"
    return 1
  fi

  echo -e "${GREEN}[MediaWiki] LocalSettings synced (URL, database, site name)${NC}"
}

mw_append_block() {
  local settings="$1" marker="$2"
  if grep -qF "$marker" "$settings" 2>/dev/null; then
    return 0
  fi
  cat >>"$settings"
}

mw_apply_wiki_entrypoints() {
  local settings="$1"
  [[ -f "$settings" ]] || return 0
  mw_append_block "$settings" "# BEGIN PTERODACTYL ENTRY POINTS" <<'EOF'

# OSRS-style short URLs (Special:Version entry point layout)
$wgArticlePath = '/w/$1';
$wgScriptPath = '';
$wgScript = '/index.php';
if ( !isset( $wgActionPaths ) || !is_array( $wgActionPaths ) ) {
	$wgActionPaths = [];
}
$wgActionPaths['api'] = '/api.php';
$wgActionPaths['rest'] = '/rest.php';
$wgMainPageIsDomainRoot = true;
$wgDefaultSkin = 'vector';
$wgDefaultMobileSkin = 'minerva';
# END PTERODACTYL ENTRY POINTS
EOF
}

mw_apply_cache_extensions() {
  local settings="$1"
  [[ -f "$settings" ]] || return 0
  if ! is_enabled "$REDIS_STATUS"; then
    mw_append_block "$settings" "# BEGIN PTERODACTYL APCU" <<'EOF'

if ( extension_loaded( 'apcu' ) && ini_get( 'apc.enabled' ) ) {
	$wgMainCacheType = CACHE_ACCEL;
}
# END PTERODACTYL APCU
EOF
  fi
}

mw_apply_debug_settings() {
  local settings="$1"
  [[ -f "$settings" ]] || return 0
  if is_enabled "${MW_DEBUG:-0}"; then
    mw_append_block "$settings" "# BEGIN PTERODACTYL DEBUG" <<'EOF'

# Enable detailed exception output and a debug log when debug mode is turned on via MW_DEBUG
$wgShowExceptionDetails = true;
$wgDebugLogFile = __DIR__ . '/debug.log';
ini_set( 'display_errors', 1 );

# END PTERODACTYL DEBUG
EOF
  fi
}

mw_prepare_images_security() {
  local img="${WWW_DIR}/images"
  mkdir -p "$img"
  chmod 755 "$img" 2>/dev/null || true
  if [[ ! -f "${img}/README" ]]; then
    echo 'This directory stores uploaded media.' >"${img}/README"
  fi
  if [[ ! -f "${img}/.htaccess" ]]; then
    cat >"${img}/.htaccess" <<'EOF'
# Disable PHP execution in the upload directory (Manual:Security)
<FilesMatch "\.ph(p[3457]?|t|tml)$">
  Require all denied
</FilesMatch>
EOF
  fi
}

mw_ensure_web_stack_for_install() {
  # shellcheck source=../lib/web-stack.sh
  if [[ ! -f "${MW_LIB_DIR}/web-stack.sh" ]]; then
    echo -e "${YELLOW}[MediaWiki] web-stack.sh not found at ${MW_LIB_DIR}/web-stack.sh — skipping pre-install web check${NC}"
    return 0
  fi
  # shellcheck source=../lib/web-stack.sh
  source "${MW_LIB_DIR}/web-stack.sh"
  if web_stack_ensure_running "$CONTAINER_ROOT" "http://127.0.0.1/images/README"; then
    echo -e "${GREEN}[MediaWiki] Web stack ready for installer security checks${NC}"
    return 0
  fi
  echo -e "${YELLOW}[MediaWiki] Starting PHP-FPM/nginx for installer checks…${NC}"
  if web_stack_ensure_running "$CONTAINER_ROOT" "http://127.0.0.1/images/README"; then
    echo -e "${GREEN}[MediaWiki] Web stack ready for installer security checks${NC}"
  else
    echo -e "${YELLOW}[MediaWiki] Could not reach http://127.0.0.1/images/README — nosniff warning may still appear.${NC}"
  fi
}

mw_resolve_server_url

if [[ -f "${MW_LIB_DIR}/php-mediawiki-setup.sh" ]]; then
  # shellcheck source=../lib/php-mediawiki-setup.sh
  source "${MW_LIB_DIR}/php-mediawiki-setup.sh"
  php_mediawiki_configure "$CONTAINER_ROOT"
fi

# Ensure LuaSandbox, Wikidiff2 and Pygments are available; attempt runtime install if missing.
if ! php -r 'exit(extension_loaded("luasandbox") && extension_loaded("wikidiff2") ? 0 : 1);' 2>/dev/null; then
  echo -e "${YELLOW}[MediaWiki] LuaSandbox or Wikidiff2 missing; attempting runtime install (may take several minutes)${NC}"
  mw_local_php_ext_dirs
  if [[ $EUID -ne 0 ]]; then
    echo -e "${YELLOW}[MediaWiki] Running as non-root; attempting local extension install in /home/container/php/extensions${NC}"
    if ! command -v pecl >/dev/null 2>&1 || ! command -v phpize >/dev/null 2>&1 || ! command -v php-config >/dev/null 2>&1; then
      echo -e "${YELLOW}[MediaWiki] Local install skipped: build tools unavailable. Build the Docker image with LuaSandbox/Wikidiff2 installed instead.${NC}"
    else
      echo -e "${YELLOW}[MediaWiki] Installing LuaSandbox locally...${NC}"
      mw_build_user_extension luasandbox luasandbox ""
      echo -e "${YELLOW}[MediaWiki] Installing excimer locally...${NC}"
      mw_build_user_extension excimer excimer ""
      echo -e "${YELLOW}[MediaWiki] Installing Wikidiff2 locally...${NC}"
      mw_build_user_extension wikidiff2 wikidiff2 "https://releases.wikimedia.org/wikidiff2/wikidiff2-1.14.1.tar.gz"
      echo -e "${GREEN}[MediaWiki] Local extension install finished. Check php -m for luasandbox/wikidiff2/excimer${NC}"
    fi
  elif [[ ! -w "/etc/php/${PHP_VERSION}/mods-available" ]]; then
    echo -e "${YELLOW}[MediaWiki] Runtime module install skipped: PHP mods directory is read-only. Build the Docker image with LuaSandbox/Wikidiff2 installed instead.${NC}"
  elif ! command -v pecl >/dev/null 2>&1; then
    echo -e "${YELLOW}[MediaWiki] Runtime module install skipped: pecl is not installed in this image. Build the Docker image with LuaSandbox/Wikidiff2 installed instead.${NC}"
  elif ! command -v apt-get >/dev/null 2>&1; then
    echo -e "${YELLOW}[MediaWiki] Runtime module install skipped: apt-get is not available in this image. Build the Docker image with LuaSandbox/Wikidiff2 installed instead.${NC}"
  else
    # Install build dependencies (best-effort)
    apt-get update -qq >/dev/null 2>&1 || true
    apt-get install -y --no-install-recommends build-essential pkg-config wget ca-certificates \
      "php${PHP_VERSION}-dev" php-pear liblua5.1-0-dev libthai-dev zlib1g-dev libzip-dev python3 python3-pip git || true

    # Install LuaSandbox via PECL
    yes '' | pecl install luasandbox-4.1.3 || true
    echo "extension=luasandbox.so" >/etc/php/${PHP_VERSION}/mods-available/luasandbox.ini || true
    phpenmod -v "${PHP_VERSION}" luasandbox 2>/dev/null || true

    # Install Excimer via PECL for Speedscope
    yes '' | pecl install excimer || true
    echo "extension=excimer.so" >/etc/php/${PHP_VERSION}/mods-available/excimer.ini || true
    phpenmod -v "${PHP_VERSION}" excimer 2>/dev/null || true

    # Build and install Wikidiff2
    WIKIDIFF2_VER="1.14.1"
    WIKIDIFF2_TGZ="/tmp/wikidiff2-${WIKIDIFF2_VER}.tar.gz"
    if [[ ! -f "$WIKIDIFF2_TGZ" ]]; then
      wget -q -O "$WIKIDIFF2_TGZ" "https://releases.wikimedia.org/wikidiff2/wikidiff2-${WIKIDIFF2_VER}.tar.gz" || true
    fi
    rm -rf /tmp/wikidiff2-src || true
    mkdir -p /tmp/wikidiff2-src || true
    tar -xzf "$WIKIDIFF2_TGZ" -C /tmp/wikidiff2-src --strip-components=1 || true
    if [[ -d /tmp/wikidiff2-src ]]; then
      cd /tmp/wikidiff2-src || true
      phpize${PHP_VERSION} || true
      ./configure --with-php-config="/usr/bin/php-config${PHP_VERSION}" --with-icu-dir=/usr/local || true
      make -j"$(nproc)" || true
      make install || true
      echo "extension=wikidiff2.so" >/etc/php/${PHP_VERSION}/mods-available/wikidiff2-built.ini || true
      phpenmod -v "${PHP_VERSION}" wikidiff2-built 2>/dev/null || true
    fi

    # Ensure Pygments installed
    if command -v pip3 >/dev/null 2>&1; then
      pip3 install --no-cache-dir Pygments || true
    fi

    # Restart PHP-FPM if available
    service php${PHP_VERSION}-fpm restart 2>/dev/null || systemctl restart php${PHP_VERSION}-fpm 2>/dev/null || true
    echo -e "${GREEN}[MediaWiki] Runtime module install attempt finished. Check php -m for luasandbox/wikidiff2${NC}"
  fi
fi

SETTINGS="${WWW_DIR}/LocalSettings.php"
if [[ -f "$SETTINGS" ]]; then
  mw_sync_localsettings_from_panel "$SETTINGS"
  mw_apply_wiki_entrypoints "$SETTINGS"
  mw_apply_cache_extensions "$SETTINGS"
  echo -e "${GREEN}[MediaWiki] Wiki URL: ${MW_SERVER} | DB: ${DB_USER}@${DB_HOST}:${DB_PORT}/${DB_NAME}${NC}"
  if ! is_enabled "$AUTOINSTALL_STATUS"; then
    exit 0
  fi
  echo -e "${YELLOW}[MediaWiki] LocalSettings.php exists; skipping auto-install.${NC}"
  exit 0
fi

if ! is_enabled "$AUTOINSTALL_STATUS"; then
  exit 0
fi

if [[ ! -f "${WWW_DIR}/index.php" ]]; then
  echo -e "${RED}[MediaWiki] MediaWiki not found in ${WWW_DIR}. Reinstall the server.${NC}"
  exit 1
fi

mw_resolve_php_bin

# MediaWiki MySQL ignores $wgDBport during install; host must include :port (see T38300).

MW_DB_INSTALL_SERVER="$(mw_db_mysqli_server)"

wait_for_database() {
  local tries=30
  echo -e "${WHITE}[MediaWiki] Waiting for MariaDB on ${DB_HOST}:${DB_PORT}…${NC}"
  while [[ "$tries" -gt 0 ]]; do
    if test_db_connection_quiet; then
      return 0
    fi
    sleep 1
    tries=$((tries - 1))
  done
  return 1
}

test_db_connection_quiet() {
  export DB_HOST DB_PORT DB_USER DB_PASSWORD
  "$PHP_BIN" -r '
mysqli_report(MYSQLI_REPORT_OFF);
ini_set("default_socket_timeout", "5");
$m = mysqli_init();
if (!$m) { exit(1); }
mysqli_options($m, MYSQLI_OPT_CONNECT_TIMEOUT, 5);
exit(@mysqli_real_connect(
  $m,
  getenv("DB_HOST"),
  getenv("DB_USER"),
  getenv("DB_PASSWORD"),
  null,
  (int)getenv("DB_PORT"),
  null,
  0
) ? 0 : 1);
' 2>/dev/null
}

test_db_connection() {
  echo -e "${WHITE}[MediaWiki] Testing database ${DB_HOST}:${DB_PORT} (5s timeout)…${NC}"
  export DB_HOST DB_PORT DB_USER DB_PASSWORD DB_NAME
  if ! "$PHP_BIN" -r '
mysqli_report(MYSQLI_REPORT_OFF);
ini_set("default_socket_timeout", "5");
$port = (int)getenv("DB_PORT");
$m = mysqli_init();
if (!$m) { exit(1); }
mysqli_options($m, MYSQLI_OPT_CONNECT_TIMEOUT, 5);
$ok = @mysqli_real_connect(
  $m,
  getenv("DB_HOST"),
  getenv("DB_USER"),
  getenv("DB_PASSWORD"),
  null,
  $port,
  null,
  0
);
if (!$ok) {
  fwrite(STDERR, mysqli_connect_error() . PHP_EOL);
  exit(1);
}
mysqli_close($m);
'; then
    echo -e "${RED}[MediaWiki] Cannot reach MySQL at ${DB_HOST}:${DB_PORT}${NC}"
    if is_enabled "$DB_STATUS"; then
      echo -e "${YELLOW}[MediaWiki] Bundled DB should be running — check logs/mariadb.log${NC}"
    else
      echo -e "${YELLOW}[MediaWiki] Use 127.0.0.1 or the DB container internal IP, not the public IP.${NC}"
    fi
    exit 1
  fi
  echo -e "${GREEN}[MediaWiki] Database connection OK${NC}"
}

# shellcheck source=../lib/mediawiki-extensions.sh
source "${MW_LIB_DIR}/mediawiki-extensions.sh"

header "Fetching extensions and skins"
mw_resolve_all_extensions
mw_resolve_skins
echo -e "${WHITE}[MediaWiki] Extensions ready: ${RESOLVED_EXTENSIONS:-none}${NC}"
echo -e "${WHITE}[MediaWiki] Skins ready: ${RESOLVED_SKINS:-none}${NC}"

if is_enabled "$MW_UPDATE"; then
  header "Update mode enabled"
  mw_update_mode
  echo -e "${GREEN}[MediaWiki] Update-only mode complete; exiting without installer.${NC}"
  exit 0
fi

header "Installing Composer dependencies"
cd "$WWW_DIR"
if [[ -f composer.json ]] && command -v composer >/dev/null 2>&1; then
  echo -e "${WHITE}[MediaWiki] Running composer install for extensions…${NC}"
  # Install without --no-dev first to ensure all extension dependencies (like wikimedia/equivset) are pulled in
  if COMPOSER_MEMORY_LIMIT=-1 composer install --no-dev --optimize-autoloader --no-interaction --prefer-dist --no-progress -o 2>&1 | tail -n 100; then
    echo -e "${GREEN}[MediaWiki] Composer dependencies installed successfully${NC}"
  else
    echo -e "${YELLOW}[MediaWiki] Warning: composer install failed with status $?. Wiki may have missing dependencies.${NC}"
  fi
else
  echo -e "${YELLOW}[MediaWiki] composer.json not found or composer CLI not available; skipping Composer install${NC}"
fi

mw_install_extension_composer_dependencies

header "Running MediaWiki CLI installer (${DB_HOST}:${DB_PORT}/${DB_NAME})"

cd "$WWW_DIR"

if is_enabled "$DB_STATUS"; then
  wait_for_database || {
    echo -e "${RED}[MediaWiki] MariaDB is not reachable on ${DB_HOST}:${DB_PORT}${NC}"
    echo -e "${YELLOW}[MediaWiki] Check logs/mariadb.log and the database module output.${NC}"
    exit 1
  }
fi

test_db_connection

echo -e "${WHITE}[MediaWiki] Preparing upload directory security…${NC}"
mw_prepare_images_security

echo -e "${WHITE}[MediaWiki] Ensuring web server for installer checks (background nginx)…${NC}"
mw_ensure_web_stack_for_install

# Installer HTTP checks use --server; use loopback (nginx :80). Public URL applied after install.
MW_INSTALL_SERVER="http://127.0.0.1"
echo -e "${WHITE}[MediaWiki] CLI install uses ${MW_INSTALL_SERVER} for checks; wiki URL will be ${MW_SERVER}${NC}"
echo -e "${YELLOW}[MediaWiki] Note: MediaWiki always prints one CLI upload-scan warning; nginx blocks PHP in /images/.${NC}"

INSTALL_ARGS=(
  maintenance/run.php install
  --server="${MW_INSTALL_SERVER}"
  --scriptpath=""
  --lang="${MW_LANG}"
  --dbtype=mysql
  --dbserver="${MW_DB_INSTALL_SERVER}"
  --dbname="${DB_NAME}"
  --dbuser="${DB_USER}"
  --dbpass="${DB_PASSWORD}"
  --pass="${MW_ADMIN_PASS}"
)

# Bundled DB: database module already created DB + user — install as wiki user (not root).
# Avoids install.php GRANT ...@'host:port' bug and matches mysqli host:port.
if is_enabled "$DB_STATUS"; then
  echo -e "${WHITE}[MediaWiki] Installing with pre-created DB user ${DB_USER}@${DB_HOST}:${DB_PORT}${NC}"
else
  INSTALL_ARGS+=(
    --installdbuser="${DB_INSTALL_USER}"
    --installdbpass="${DB_INSTALL_PASS}"
  )
fi

if [[ -n "${RESOLVED_EXTENSIONS:-}" ]]; then
  echo -e "${WHITE}[MediaWiki] Installing extensions: ${RESOLVED_EXTENSIONS}${NC}"
  INSTALL_ARGS+=(--extensions="${RESOLVED_EXTENSIONS}")
else
  echo -e "${YELLOW}[MediaWiki] No extensions resolved; running core install only.${NC}"
fi

if [[ -n "${RESOLVED_SKINS:-}" ]]; then
  echo -e "${WHITE}[MediaWiki] Installing skins: ${RESOLVED_SKINS}${NC}"
  INSTALL_ARGS+=(--skins="${RESOLVED_SKINS}")
fi

echo -e "${WHITE}[MediaWiki] Starting CLI install (core + extensions — often 2–10 minutes, please wait)…${NC}"
if ! "$PHP_BIN" -d output_buffering=Off -d implicit_flush=1 \
  "${INSTALL_ARGS[@]}" "${MW_SITE_NAME}" "${MW_ADMIN_USER}"; then
  echo -e "${RED}[MediaWiki] CLI install failed. Check DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASSWORD.${NC}"
  exit 1
fi

header "Applying LocalSettings.php extras"

SETTINGS="${WWW_DIR}/LocalSettings.php"
if [[ ! -f "$SETTINGS" ]]; then
  echo -e "${RED}[MediaWiki] LocalSettings.php was not created.${NC}"
  exit 1
fi

mw_sync_localsettings_from_panel "$SETTINGS"
mw_apply_wiki_entrypoints "$SETTINGS"
mw_apply_cache_extensions "$SETTINGS"
mw_apply_debug_settings "$SETTINGS"

if is_enabled "$REDIS_STATUS"; then
  mw_append_block "$SETTINGS" "# BEGIN PTERODACTYL REDIS" <<EOF

if ( extension_loaded( 'redis' ) || class_exists( Redis::class ) ) {
	\$wgMainCacheType = CACHE_REDIS;
	\$wgSessionCacheType = CACHE_REDIS;
	\$wgRedisServers = [ '${REDIS_HOST}:${REDIS_PORT}' ];
}
if ( is_readable( __DIR__ . '/extensions/Redis/extension.json' ) ) {
	wfLoadExtension( 'Redis' );
}
# END PTERODACTYL REDIS
EOF
fi

if is_enabled "$ELASTICSEARCH_STATUS"; then
  mw_append_block "$SETTINGS" "# BEGIN PTERODACTYL ELASTICSEARCH" <<EOF

wfLoadExtension( 'Elastica' );
wfLoadExtension( 'CirrusSearch' );
\$wgSearchType = 'CirrusSearch';
\$wgSearchTypeAlternatives = [ 'CirrusSearch' ];
\$wgElasticsearchServers = [ '${ELASTICSEARCH_HOST}' ];
# END PTERODACTYL ELASTICSEARCH
EOF
fi

mw_append_block "$SETTINGS" "# BEGIN PTERODACTYL CACHE PATHS" <<EOF

\$wgCacheDirectory = '${CONTAINER_ROOT}/cache';
\$wgTmpDirectory = '${CONTAINER_ROOT}/tmp';
# END PTERODACTYL CACHE PATHS
EOF

mkdir -p "${CONTAINER_ROOT}/cache" "${CONTAINER_ROOT}/tmp"
chmod 755 "${CONTAINER_ROOT}/cache" "${CONTAINER_ROOT}/tmp" 2>/dev/null || true

header "Final Composer install (if needed)"
cd "$WWW_DIR"
if [[ -f composer.json ]] && command -v composer >/dev/null 2>&1; then
  echo -e "${WHITE}[MediaWiki] Running final composer install…${NC}"
  if COMPOSER_MEMORY_LIMIT=-1 composer install --no-dev --optimize-autoloader --no-interaction --prefer-dist --no-progress -o 2>&1 | tail -n 100; then
    echo -e "${GREEN}[MediaWiki] Composer dependencies finalized${NC}"
  else
    echo -e "${YELLOW}[MediaWiki] Warning: final composer install failed. Wiki may have missing dependencies.${NC}"
  fi
fi

echo -e "${GREEN}[MediaWiki] Installed successfully.${NC}"
echo -e "${GREEN}[MediaWiki] URL: ${MW_SERVER}${NC}"
echo -e "${GREEN}[MediaWiki] Admin: ${MW_ADMIN_USER}${NC}"
