#!/usr/bin/env bash
# Configure PHP for MediaWiki: load system extensions + verify modules.

php_mediawiki_cli_bin() {
  local ver="${PHP_VERSION:-8.4}"
  if command -v "php${ver}" >/dev/null 2>&1; then
    echo "php${ver}"
    return 0
  fi
  if command -v php >/dev/null 2>&1; then
    echo php
    return 0
  fi
  return 1
}

php_mediawiki_configure() {
  local root="${1:-/home/container}"
  local ver="${PHP_VERSION:-8.4}"
  local php_ini="${root}/php/php.ini"
  local fpm_scan="/etc/php/${ver}/fpm/conf.d"
  local cli_scan="/etc/php/${ver}/cli/conf.d"
  local egg_conf="${root}/php/conf.d"

  mkdir -p "$egg_conf"

  # Load Sury extension modules + egg tuning when using -c /home/container/php/php.ini
  local scan_paths=""
  [[ -d "$fpm_scan" ]] && scan_paths="${fpm_scan}"
  [[ -d "$cli_scan" ]] && scan_paths="${scan_paths}${scan_paths:+:}${cli_scan}"
  [[ -d "$egg_conf" ]] && scan_paths="${scan_paths}${scan_paths:+:}${egg_conf}"

  if [[ -n "$scan_paths" ]]; then
    if grep -qE '^[[:space:]]*scan_dir[[:space:]]*=' "$php_ini" 2>/dev/null; then
      sed -i "s|^[[:space:]]*scan_dir[[:space:]]*=.*|scan_dir = ${scan_paths}|" "$php_ini"
    else
      sed -i "/^\[PHP\]/a scan_dir = ${scan_paths}" "$php_ini"
    fi
  fi
}

php_mediawiki_has_module() {
  local php_bin="$1" ext="$2" php_ini="${3:-}"

  local -a args=()
  [[ -n "$php_ini" && -f "$php_ini" ]] && args=(-c "$php_ini")

  case "${ext,,}" in
    json)
      "${php_bin}" "${args[@]}" -r 'exit(function_exists("json_encode")?0:1);' 2>/dev/null
      return $?
      ;;
    openssl)
      "${php_bin}" "${args[@]}" -r 'exit(extension_loaded("openssl")?0:1);' 2>/dev/null
      return $?
      ;;
  esac

  "${php_bin}" "${args[@]}" -m 2>/dev/null | grep -qi "^${ext}$"
}

php_mediawiki_verify_extensions() {
  local root="${1:-/home/container}"
  local php_ini="${root}/php/php.ini"
  local php_bin
  local -a required=(
    intl mbstring xml xmlreader ctype iconv fileinfo dom
    calendar sodium curl mysqli zip exif gd json openssl
  )
  local -a recommended=( apcu imagick )
  local ext missing=() rec_missing=()

  if ! php_bin=$(php_mediawiki_cli_bin); then
    echo -e "\033[0;33m[PHP] Cannot verify extensions — PHP CLI not found\033[0m"
    return 0
  fi

  for ext in "${required[@]}"; do
    php_mediawiki_has_module "$php_bin" "$ext" "$php_ini" || missing+=("$ext")
  done

  php_mediawiki_has_module "$php_bin" apcu "$php_ini" || rec_missing+=("apcu")
  php_mediawiki_has_module "$php_bin" imagick "$php_ini" || rec_missing+=("imagick")
  php_mediawiki_has_module "$php_bin" luasandbox "$php_ini" || rec_missing+=("luasandbox")
  php_mediawiki_has_module "$php_bin" wikidiff2 "$php_ini" || rec_missing+=("wikidiff2")
  php_mediawiki_has_module "$php_bin" excimer "$php_ini" || rec_missing+=("excimer")
  if ! "${php_bin}" -c "$php_ini" -m 2>/dev/null | grep -qi opcache; then
    rec_missing+=("opcache")
  fi

  if [[ ${#missing[@]} -gt 0 ]]; then
    echo -e "\033[0;33m[PHP] Missing required extensions: ${missing[*]}\033[0m"
    echo -e "\033[0;33m[PHP] Rebuild Docker image (mediawiki-pterodactyl-egg:${PHP_VERSION:-?}-latest)\033[0m"
  else
    echo -e "\033[0;32m[PHP] MediaWiki required extensions OK\033[0m"
  fi

  if [[ ${#rec_missing[@]} -gt 0 ]]; then
    echo -e "\033[0;33m[PHP] Optional extensions not loaded: ${rec_missing[*]}\033[0m"
  fi
}
